class Caveats
  attr_reader :f

  def initialize(f)
    @f = f
  end

  def caveats
    caveats = []
    begin
      build = f.build
      f.build = Tab.for_formula(f)
      s = f.caveats.to_s
      caveats << s.chomp + "\n" unless s.empty?
    ensure
      f.build = build
    end
    caveats << keg_only_text
    caveats << function_completion_caveats(:bash)
    caveats << function_completion_caveats(:zsh)
    caveats << function_completion_caveats(:fish)
    caveats << plist_caveats
    caveats << python_caveats
    caveats << elisp_caveats
    caveats.compact.join("\n")
  end

  def empty?
    caveats.empty?
  end

  private

  def keg
    @keg ||= [f.prefix, f.opt_prefix, f.linked_keg].map do |d|
      begin
        Keg.new(d.resolved_path)
      rescue
        nil
      end
    end.compact.first
  end

  def keg_only_text
    return unless f.keg_only?

    s = "This formula is keg-only, which means it was not symlinked into #{HOMEBREW_PREFIX}."
    s << "\n\n#{f.keg_only_reason}\n"
    if f.bin.directory? || f.sbin.directory?
      s << "\nIf you need to have this software first in your PATH run:\n"
      if f.bin.directory?
        s << "  #{Utils::Shell.prepend_path_in_shell_profile(f.opt_bin.to_s)}\n"
      end
      if f.sbin.directory?
        s << "  #{Utils::Shell.prepend_path_in_shell_profile(f.opt_sbin.to_s)}\n"
      end
    end

    if f.lib.directory? || f.include.directory?
      s << "\nFor compilers to find this software you may need to set:\n"
      s << "    LDFLAGS:  -L#{f.opt_lib}\n" if f.lib.directory?
      s << "    CPPFLAGS: -I#{f.opt_include}\n" if f.include.directory?
      if which("pkg-config") &&
         ((f.lib/"pkgconfig").directory? || (f.share/"pkgconfig").directory?)
        s << "For pkg-config to find this software you may need to set:\n"
        s << "    PKG_CONFIG_PATH: #{f.opt_lib}/pkgconfig\n" if (f.lib/"pkgconfig").directory?
        s << "    PKG_CONFIG_PATH: #{f.opt_share}/pkgconfig\n" if (f.share/"pkgconfig").directory?
      end
    end
    s << "\n"
  end

  def function_completion_caveats(shell)
    return unless keg
    return unless which(shell.to_s)

    completion_installed = keg.completion_installed?(shell)
    functions_installed = keg.functions_installed?(shell)
    return unless completion_installed || functions_installed

    installed = []
    installed << "completions" if completion_installed
    installed << "functions" if functions_installed

    case shell
    when :bash
      <<-EOS.undent
        Bash completion has been installed to:
          #{HOMEBREW_PREFIX}/etc/bash_completion.d
      EOS
    when :zsh
      <<-EOS.undent
        zsh #{installed.join(" and ")} have been installed to:
          #{HOMEBREW_PREFIX}/share/zsh/site-functions
      EOS
    when :fish
      fish_caveats = "fish #{installed.join(" and ")} have been installed to:"
      fish_caveats << "\n  #{HOMEBREW_PREFIX}/share/fish/vendor_completions.d" if completion_installed
      fish_caveats << "\n  #{HOMEBREW_PREFIX}/share/fish/vendor_functions.d" if functions_installed
      fish_caveats
    end
  end

  def python_caveats
    return unless keg
    formula_packages = Dir[f.opt_prefix/"lib/python*.*/site-packages"]
    return if formula_packages.empty?

    python_from_path = lambda do |path|
      path.to_s.match(%r{lib/(python(\d+\.\d+))/site-packages}).captures
    end

    # instructions for adding the Homebrew prefix's site-packages to sys.path
    # by creating a .pth file in the user site-packages directory; may be the
    # empty string if this is already okay
    homebrew_site_package_instructions = formula_packages.map do |path|
      python, python_version = python_from_path[path]
      next if Language::Python.reads_brewed_pth_files?(python)
      homebrew_site_packages = Language::Python.homebrew_site_packages(python_version)
      user_site_packages = Language::Python.user_site_packages(python)
      next unless user_site_packages
      pth_file = user_site_packages/"homebrew.pth"
      <<-EOS.undent.gsub(/^/, "  ")
        mkdir -p #{user_site_packages}
        echo 'import site; site.addsitedir("#{homebrew_site_packages}")' >> #{pth_file}
      EOS
    end.compact.join("\n")

    output = []

    if f.keg_only?
      commands = formula_packages.map do |path|
        python, python_version = python_from_path[path]
        homebrew_site_packages = Language::Python.homebrew_site_packages(python_version)
        next if Language::Python.in_sys_path?(python, path)
        "  echo 'import site; site.addsitedir(\"#{path}\")' >> #{homebrew_site_packages/f.name}.pth"
      end.compact

      unless commands.empty?
        output << <<-EOS.undent.rstrip
          If you need Python to find bindings for this keg-only formula, run:
        EOS
        output += commands
        output << homebrew_site_package_instructions unless homebrew_site_package_instructions.empty?
        return output.join("\n")
      end
    end

    return if homebrew_site_package_instructions.empty?

    missing_from_sys_path = formula_packages.any? do |path|
      python, python_version = python_from_path[path]
      homebrew_site_packages = Language::Python.homebrew_site_packages(python_version)
      !Language::Python.in_sys_path?(python, homebrew_site_packages)
    end

    if missing_from_sys_path
      output << <<-EOS.undent.rstrip
        Python modules have been installed and Homebrew's site-packages is not
        in your Python sys.path, so you will not be able to import the modules
        this formula installed. If you plan to develop with these modules,
        please run:
      EOS
    else
      pth_files = formula_packages.map { |p| Dir[p + "/*.pth"] }.flatten
      return if pth_files.empty?
      output << <<-EOS.undent.rstrip
        This formula installed .pth files to Homebrew's site-packages and your
        Python isn't configured to process them, so you will not be able to
        import the modules this formula installed. If you plan to develop
        with these modules, please run:
      EOS
    end

    output << homebrew_site_package_instructions
    output.join("\n")
  end

  def elisp_caveats
    return if f.keg_only?
    return unless keg
    return unless keg.elisp_installed?

    <<-EOS.undent
      Emacs Lisp files have been installed to:
        #{HOMEBREW_PREFIX}/share/emacs/site-lisp/#{f.name}
    EOS
  end

  def plist_caveats
    s = []
    if f.plist || (keg && keg.plist_installed?)
      destination = if f.plist_startup
        "/Library/LaunchDaemons"
      else
        "~/Library/LaunchAgents"
      end

      plist_filename = if f.plist
        f.plist_path.basename
      else
        File.basename Dir["#{keg}/*.plist"].first
      end
      plist_domain = f.plist_path.basename(".plist")
      destination_path = Pathname.new File.expand_path destination
      plist_path = destination_path/plist_filename

      # we readlink because this path probably doesn't exist since caveats
      # occurs before the link step of installation
      # Yosemite security measures mildly tighter rules:
      # https://github.com/Homebrew/legacy-homebrew/issues/33815
      if !plist_path.file? || !plist_path.symlink?
        if f.plist_startup
          s << "To have launchd start #{f.full_name} now and restart at startup:"
          s << "  sudo brew services start #{f.full_name}"
        else
          s << "To have launchd start #{f.full_name} now and restart at login:"
          s << "  brew services start #{f.full_name}"
        end
      # For startup plists, we cannot tell whether it's running on launchd,
      # as it requires for `sudo launchctl list` to get real result.
      elsif f.plist_startup
        s << "To restart #{f.full_name} after an upgrade:"
        s << "  sudo brew services restart #{f.full_name}"
      elsif Kernel.system "/bin/launchctl list #{plist_domain} &>/dev/null"
        s << "To restart #{f.full_name} after an upgrade:"
        s << "  brew services restart #{f.full_name}"
      else
        s << "To start #{f.full_name}:"
        s << "  brew services start #{f.full_name}"
      end

      if f.plist_manual
        s << "Or, if you don't want/need a background service you can just run:"
        s << "  #{f.plist_manual}"
      end

      if ENV["TMUX"] && !quiet_system("/usr/bin/pbpaste")
        s << "" << "WARNING: brew services will fail when run under tmux."
      end
    end
    s.join("\n") + "\n" unless s.empty?
  end
end
