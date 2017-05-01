require "formula"
require "caveats"
require "language/python"

describe Caveats do
  subject { described_class.new(f) }
  let(:f) { formula { url "foo-1.0" } }

  specify "#f" do
    expect(subject.f).to eq(f)
  end

  describe "#empty?" do
    it "returns true if the Formula has no caveats" do
      expect(subject).to be_empty
    end

    it "returns false if the Formula has caveats" do
      f = formula do
        url "foo-1.0"

        def caveats
          "something"
        end
      end

      expect(described_class.new(f)).not_to be_empty
    end
  end

  describe "#python_caveats" do
    subject { described_class.new(f).send(:python_caveats) }

    let(:packages27) { f.lib/"python2.7/site-packages" }
    let(:packages34) { f.lib/"python3.4/site-packages" }

    before do
      f.prefix.mkpath
      f.opt_prefix.parent.mkpath
      FileUtils.ln_s f.prefix, f.opt_prefix
    end

    context "when python sees our site-packages" do
      before do
        allow(Language::Python).to receive(:reads_brewed_pth_files?).and_return(true)
      end
      context "and site-packages is empty" do
        it { is_expected.to be_nil }
      end
      context "and a 2.7 site-packages exists" do
        before { packages27.mkpath }
        it { is_expected.to be_nil }
      end

      context "and formula is keg-only" do
        before { allow(f).to receive(:keg_only?).and_return(true) }
        context "and site-packages is empty" do
          it { is_expected.to be_nil }
        end
        context "and a 2.7 site-packages exists" do
          before { packages27.mkpath }
          it { is_expected.to include("keg-only") }
        end
      end
    end

    context "when python doesn't see our site-packages at all" do
      before do
        allow(Language::Python).to receive(:reads_brewed_pth_files?).and_return(false)
        allow(Language::Python).to receive(:in_sys_path?).and_return(false)
        allow(Language::Python).to receive(:user_site_packages).and_return(Pathname.new("user_site_packages"))
      end
      context "and site-packages is empty" do
        it { is_expected.to be_nil }
      end
      context "and a 2.7 site-packages exists" do
        before { packages27.mkpath }
        it("should mention 2.7") { is_expected.to include("2.7") }
        it("should not mention python3") { is_expected.to_not include("python3") }
      end
      context "and both 2.7 and 3.4 site-packages exists" do
        before do
          packages27.mkpath
          packages34.mkpath
        end
        it("should mention 2.7") { is_expected.to include("2.7") }
        it("should mention 3.4") { is_expected.to include("3.4") }
      end
    end

    context "when our site-packages is in sys.path but .pth files aren't read" do
      before do
        allow(Language::Python).to receive(:reads_brewed_pth_files?).and_return(false)
        allow(Language::Python).to receive(:in_sys_path?).and_return(true)
        allow(Language::Python).to receive(:user_site_packages).and_return(Pathname.new("user_site_packages"))
      end
      context "and site-packages is empty" do
        it { is_expected.to be_nil }
      end
      context "and an empty 2.7 site-packages exists" do
        before { packages27.mkpath }
        it { is_expected.to be_nil }
      end
      context "and a 2.7 site-packages exists with a .pth file" do
        before do
          packages27.mkpath
          (packages27/"hello.pth").write ""
        end
        it { is_expected.not_to be_nil }
      end
    end
  end
end
