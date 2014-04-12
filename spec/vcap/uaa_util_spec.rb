require "spec_helper"
require "vcap/uaa_util"

module VCAP
  describe UaaTokenDecoder do
    subject { described_class.new(config_hash) }

    let(:config_hash) do
      { :resource_id => "resource-id",
        :symmetric_secret => nil }
    end
    
    let(:uaa_info) { double(CF::UAA::Info) }
    let(:logger) { double(Steno::Logger) }

    before do
      allow(CF::UAA::Info).to receive(:new).and_return(uaa_info)
      allow(Steno).to receive(:logger).with('cc.uaa_token_decoder').and_return(logger)
    end

    describe "#decode_token" do
      context "when symmetric key is used" do
        before { config_hash[:symmetric_secret] = "symmetric-key" }

        context "when toke is valid" do
          it "uses UAA::TokenCoder to decode the token with skey" do
            coder = double(:token_coder)
            coder.should_receive(:decode)
              .with("bearer token")
              .and_return("decoded-info")

            CF::UAA::TokenCoder.should_receive(:new).with(
              :audience_ids => "resource-id",
              :skey => "symmetric-key",
            ).and_return(coder)

            subject.decode_token("bearer token").should == "decoded-info"
          end
        end

        context "when token is invalid" do
          it "raises BadToken exception" do
            expect(logger).to receive(:warn).with(/invalid bearer token/i)

            expect {
              subject.decode_token("bearer token")
            }.to raise_error(VCAP::UaaTokenDecoder::BadToken)
          end
        end
      end

      context "when asymmetric key is used" do
        before { config_hash[:symmetric_secret] = nil }

        before { Timecop.freeze(Time.now) }
        after { Timecop.return }

        let(:rsa_key) { OpenSSL::PKey::RSA.new(2048) }
        before { uaa_info.stub(:validation_key => {"value" => rsa_key.public_key.to_pem}) }

        context "when token is valid" do
          let(:token_content) do
            {"aud" => "resource-id", "payload" => 123, "exp" => Time.now.to_i + 10_000}
          end

          it "successfully decodes token and caches key" do
            token = generate_token(rsa_key, token_content)

            uaa_info.should_receive(:validation_key)
            subject.decode_token("bearer #{token}").should == token_content

            uaa_info.should_not_receive(:validation_key)
            subject.decode_token("bearer #{token}").should == token_content
          end

          describe "re-fetching key" do
            let(:old_rsa_key) { OpenSSL::PKey::RSA.new(2048) }

            it "retries to decode token with newly fetched asymmetric key" do
              uaa_info
                .stub(:validation_key)
                .and_return(
                  {"value" => old_rsa_key.public_key.to_pem},
                  {"value" => rsa_key.public_key.to_pem},
                )
              subject.decode_token("bearer #{generate_token(rsa_key, token_content)}").should == token_content
            end

            it "stops retrying to decode token with newly fetched asymmetric key after 1 try" do
              uaa_info
                .stub(:validation_key)
                .and_return("value" => old_rsa_key.public_key.to_pem)

              expect(logger).to receive(:warn).with(/invalid bearer token/i)
              expect {
                subject.decode_token("bearer #{generate_token(rsa_key, token_content)}")
              }.to raise_error(VCAP::UaaTokenDecoder::BadToken)
            end
          end
        end

        context "when token has invalid audience" do
          let(:token_content) do
            {"aud" => "invalid-audience", "payload" => 123, "exp" => Time.now.to_i + 10_000}
          end

          it "raises an BadToken error" do
            expect(logger).to receive(:warn).with(/invalid bearer token/i)
            expect {
              subject.decode_token("bearer #{generate_token(rsa_key, token_content)}")
            }.to raise_error(VCAP::UaaTokenDecoder::BadToken)
          end
        end

        context "when token has expired" do
          let(:token_content) do
            {"aud" => "resource-id", "payload" => 123, "exp" => Time.now.to_i}
          end

          it "raises a BadToken error" do
            expect(logger).to receive(:warn).with(/token expired/i)
            expect {
              subject.decode_token("bearer #{generate_token(rsa_key, token_content)}")
            }.to raise_error(VCAP::UaaTokenDecoder::BadToken)
          end
        end

        context "when token is invalid" do
          it "raises BadToken error" do
            expect(logger).to receive(:warn).with(/invalid bearer token/i)
            expect {
              subject.decode_token("bearer invalid-token")
            }.to raise_error(VCAP::UaaTokenDecoder::BadToken)
          end
        end

        def generate_token(rsa_key, content)
          CF::UAA::TokenCoder.encode(content, {
            :pkey => rsa_key,
            :algorithm => "RS256",
          })
        end
      end
    end
  end

  describe UaaVerificationKey do
    subject { described_class.new(config_hash[:verification_key], uaa_info) }

    let(:config_hash) do
      { :url => "http://uaa-url" }
    end

    let(:uaa_info) { double(CF::UAA::Info) }

    describe "#value" do
      context "when config does not specify verification key" do
        before { config_hash[:verification_key] = nil }
        before { uaa_info.stub(:validation_key => {"value" => "value-from-uaa"}) }

        context "when key was never fetched" do
          it "is fetched" do
            expect(uaa_info).to receive(:validation_key)
            expect(subject.value).to eq "value-from-uaa"
          end
        end

        context "when key was fetched before" do
          before do
            uaa_info.should_receive(:validation_key) # sanity
            subject.value
          end

          it "is not fetched again" do
            uaa_info.should_not_receive(:validation_key)
            subject.value.should == "value-from-uaa"
          end
        end
      end

      context "when config specified verification key" do
        before { config_hash[:verification_key] = "value-from-config" }

        it "returns key specified in config" do
          subject.value.should == "value-from-config"
        end

        it "is not fetched" do
          uaa_info.should_not_receive(:validation_key)
          subject.value
        end
      end
    end

    describe "#refresh" do
      context "when config does not specify verification key" do
        before { config_hash[:verification_key] = nil }
        before { uaa_info.stub(:validation_key => {"value" => "value-from-uaa"}) }

        context "when key was never fetched" do
          it "is fetched" do
            expect(uaa_info).to receive(:validation_key)
            subject.refresh
            subject.value.should == "value-from-uaa"
          end
        end

        context "when key was fetched before" do
          before do
            uaa_info.should_receive(:validation_key) # sanity
            subject.value
          end

          it "is RE-fetched again" do
            expect(uaa_info).to receive(:validation_key)
            subject.refresh
            subject.value.should == "value-from-uaa"
          end
        end
      end

      context "when config specified verification key" do
        before { config_hash[:verification_key] = "value-from-config" }

        it "returns key specified in config" do
          subject.refresh
          subject.value.should == "value-from-config"
        end

        it "is not fetched" do
          uaa_info.should_not_receive(:validation_key)
          subject.refresh
          subject.value.should == "value-from-config"
        end
      end
    end
  end
end
