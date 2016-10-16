require "os/mac/linkage_checker"

module FormulaCellarChecks
  def check_shadowed_headers
    return if ["libtool", "subversion", "berkeley-db"].any? do |formula_name|
      formula.name.start_with?(formula_name)
    end

    return if MacOS.version < :mavericks && formula.name.start_with?("postgresql")
    return if MacOS.version < :yosemite  && formula.name.start_with?("memcached")

    return if formula.keg_only? || !formula.include.directory?

    files  = relative_glob(formula.include, "**/*.h")
    files &= relative_glob("#{MacOS.sdk_path}/usr/include", "**/*.h")
    files.map! { |p| File.join(formula.include, p) }

    return if files.empty?

    <<-EOS.undent
      Header files that shadow system header files were installed to "#{formula.include}"
      The offending files are:
        #{files * "\n        "}
    EOS
  end

  def check_openssl_links
    return unless formula.prefix.directory?
    keg = Keg.new(formula.prefix)
    system_openssl = keg.mach_o_files.select do |obj|
      dlls = obj.dynamically_linked_libraries
      dlls.any? { |dll| %r{/usr/lib/lib(crypto|ssl|tls)\..*dylib}.match dll }
    end
    return if system_openssl.empty?

    <<-EOS.undent
      object files were linked against system openssl
      These object files were linked against the deprecated system OpenSSL or
      the system's private LibreSSL.
      Adding `depends_on "openssl"` to the formula may help.
        #{system_openssl * "\n        "}
    EOS
  end

  def check_python_framework_links(lib)
    python_modules = Pathname.glob lib/"python*/site-packages/**/*.so"
    framework_links = python_modules.select do |obj|
      dlls = obj.dynamically_linked_libraries
      dlls.any? { |dll| /Python\.framework/.match dll }
    end
    return if framework_links.empty?

    <<-EOS.undent
      python modules have explicit framework links
      These python extension modules were linked directly to a Python
      framework binary. They should be linked with -undefined dynamic_lookup
      instead of -lpython or -framework Python.
        #{framework_links * "\n        "}
    EOS
  end

  def check_python_virtualenv
    return if formula_requires_python?(formula) && default_python_is_system_python?
    framework = formula.libexec/".Python"
    return unless framework.symlink?
    return unless framework.realpath.to_s.start_with?("/System")
    <<-EOS.undent
      virtualenv created against system Python
      This formula created a virtualenv using system Python.
      Please add `depends_on :python` to the formula.
    EOS
  end

  def check_python_shebangs
    return unless formula.bin.directory?
    return if formula_requires_python?(formula) && default_python_is_system_python?
    shibboleth = "#!/usr/bin/python"
    system_python_shebangs = formula.bin.children.select do |bin|
      (bin.open { |f| f.read(shibboleth.length) }) == shibboleth
    end
    return if system_python_shebangs.empty?

    <<-EOS.undent
      python scripts run with system python
      These python scripts have shebangs that invoke system Python.
      They should run Homebrew's python instead. Adding `depends_on :python`
      to the formula may help.
        #{system_python_shebangs * "\n        "}
    EOS
  end

  def check_linkage
    return unless formula.prefix.directory?
    keg = Keg.new(formula.prefix)
    checker = LinkageChecker.new(keg, formula)

    return unless checker.broken_dylibs?
    audit_check_output <<-EOS.undent
      The installation was broken.
      Broken dylib links found:
        #{checker.broken_dylibs.to_a * "\n          "}
    EOS
  end

  def audit_installed
    generic_audit_installed
    audit_check_output(check_shadowed_headers)
    audit_check_output(check_openssl_links)
    audit_check_output(check_python_framework_links(formula.lib))
    audit_check_output(check_python_virtualenv)
    audit_check_output(check_python_shebangs)
    check_linkage
  end

  def default_python_is_system_python?
    sanitized_path = ENV["PATH"]
    begin
      # Run `python` in the user's environment to get the real answer because
      # the python we find in the user's PATH might be a pyenv shim
      ENV["PATH"] = ORIGINAL_PATHS.join(File::PATH_SEPARATOR)
      which_python = which("python")
      python_exec, = Open3.capture2(which_python, "-c", "import sys; print(sys.executable)")
      python_exec = Pathname.new(python_exec.strip).realpath
    rescue => e
      opoo "Inconsistent Python environment: #{e}"
      python_exec = Pathname.new("")
    ensure
      ENV["PATH"] = sanitized_path
    end

    return nil unless python_exec.exist?
    python_exec.to_s.start_with?("/usr/bin/python")
  end

  def formula_requires_python?(formula)
    formula.requirements.any? { |r| r.name == "python" }
  end
end
