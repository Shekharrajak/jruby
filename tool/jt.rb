#!/usr/bin/env ruby
# encoding: utf-8

# Copyright (c) 2015, 2016 Oracle and/or its affiliates. All rights reserved.
# This code is released under a tri EPL/GPL/LGPL license. You can use it,
# redistribute it and/or modify it under the terms of the:
#
# Eclipse Public License version 1.0
# GNU General Public License version 2
# GNU Lesser General Public License version 2.1

# A workflow tool for JRuby+Truffle development

# Recommended: function jt { ruby tool/jt.rb "$@"; }

require 'fileutils'
require 'json'
require 'timeout'
require 'yaml'
require 'open3'

GRAALVM_VERSION = '0.15'

JRUBY_DIR = File.expand_path('../..', __FILE__)
M2_REPO = File.expand_path('~/.m2/repository')
SULONG_HOME = ENV['SULONG_HOME']

JDEBUG_PORT = 51819
JDEBUG = "-J-agentlib:jdwp=transport=dt_socket,server=y,address=#{JDEBUG_PORT},suspend=y"
JDEBUG_TEST = "-Dmaven.surefire.debug=-Xdebug -Xrunjdwp:transport=dt_socket,server=y,suspend=y,address=#{JDEBUG_PORT} -Xnoagent -Djava.compiler=NONE"
JEXCEPTION = "-Xtruffle.exceptions.print_java=true"
METRICS_REPS = 10
CEXTC_CONF_FILE = '.jruby-cext-build.yml'

VERBOSE = ENV.include? 'V'

MAC = `uname -a`.include?('Darwin')

if MAC
  SO = 'dylib'
else
  SO = 'so'
end

LIBXML_HOME = ENV['LIBXML_HOME'] = ENV['LIBXML_HOME'] || '/usr'
LIBXML_LIB_HOME = ENV['LIBXML_LIB_HOME'] = ENV['LIBXML_LIB_HOME'] || "#{LIBXML_HOME}/lib"
LIBXML_INCLUDE = ENV['LIBXML_INCLUDE'] = ENV['LIBXML_INCLUDE'] || "#{LIBXML_HOME}/include/libxml2"
LIBXML_LIB = ENV['LIBXML_LIB'] = ENV['LIBXML_LIB'] || "#{LIBXML_LIB_HOME}/libxml2.#{SO}"

OPENSSL_HOME = ENV['OPENSSL_HOME'] = ENV['OPENSSL_HOME'] || '/usr'
OPENSSL_LIB_HOME = ENV['OPENSSL_LIB_HOME'] = ENV['OPENSSL_LIB_HOME'] || "#{OPENSSL_HOME}/lib"
OPENSSL_INCLUDE = ENV['OPENSSL_INCLUDE'] = ENV['OPENSSL_INCLUDE'] || "#{OPENSSL_HOME}/include"
OPENSSL_LIB = ENV['OPENSSL_LIB'] = ENV['OPENSSL_LIB'] || "#{OPENSSL_LIB_HOME}/libssl.#{SO}"

# wait for sub-processes to handle the interrupt
trap(:INT) {}

module Utilities

  def self.truffle_version
    File.foreach("#{JRUBY_DIR}/truffle/pom.rb") do |line|
      if /'truffle\.version' => '(\d+\.\d+(?:-SNAPSHOT)?|\h+-SNAPSHOT)'/ =~ line
        break $1
      end
    end
  end

  def self.truffle_release?
    !truffle_version.include?('SNAPSHOT')
  end

  def self.find_graal_javacmd_and_options
    graalvm = ENV['GRAALVM_BIN']
    graal_home = ENV['GRAAL_HOME']

    raise "Both GRAALVM_BIN and GRAAL_HOME defined!" if graalvm && graal_home

    if !graalvm && !graal_home
      if truffle_release?
        graalvm = ENV['GRAALVM_RELEASE_BIN']
      else
        graal_home = ENV['GRAAL_HOME_TRUFFLE_HEAD']
      end
    end

    if graalvm
      javacmd = File.expand_path(graalvm)
      options = []
    elsif graal_home
      graal_home = File.expand_path(graal_home)
      if ENV['JVMCI_JAVA_HOME']
        mx_options = "--java-home #{ENV['JVMCI_JAVA_HOME']}"
      else
        mx_options = ''
      end
      command_line = `mx -v #{mx_options} -p #{graal_home} vm -version`.lines.to_a.last
      vm_args = command_line.split
      vm_args.pop # Drop "-version"
      javacmd = vm_args.shift
      if Dir.exist?("#{graal_home}/mx.sulong")
        sulong_dependencies = "#{graal_home}/lib/*"
        sulong_jar = "#{graal_home}/build/sulong.jar"
        nfi_classes = File.expand_path('../graal-core/mxbuild/graal/com.oracle.nfi/bin', graal_home)
        vm_args << '-cp'
        vm_args << [nfi_classes, sulong_dependencies, sulong_jar].join(':')
        vm_args << '-XX:-UseJVMCIClassLoader'
      end
      options = vm_args.map { |arg| "-J#{arg}" }
    else
      raise 'set one of GRAALVM_BIN or GRAAL_HOME in order to use Graal'
    end
    [javacmd, options]
  end

  def self.find_graal_js
    jar = ENV['GRAAL_JS_JAR']
    return jar if jar
    raise "couldn't find trufflejs.jar - download GraalVM as described in https://github.com/jruby/jruby/wiki/Downloading-GraalVM and find it in there"
  end

  def self.find_sl
    jar = ENV['SL_JAR']
    return jar if jar
    raise "couldn't find truffle-sl.jar - build Truffle and find it in there"
  end

  def self.jruby_eclipse?
    # tool/jruby_eclipse only works on release currently
    ENV["JRUBY_ECLIPSE"] == "true" and !truffle_version.end_with?('SNAPSHOT')
  end

  def self.mx?
    mx_ruby_jar = "#{JRUBY_DIR}/mxbuild/dists/ruby.jar"
    constants_file = "#{JRUBY_DIR}/core/src/main/java/org/jruby/runtime/Constants.java"
    File.exist?(mx_ruby_jar) && File.mtime(mx_ruby_jar) >= File.mtime(constants_file)
  end

  def self.find_ruby
    if ENV["RUBY_BIN"]
      ENV["RUBY_BIN"]
    else
      version = `ruby -e 'print RUBY_VERSION' 2>/dev/null`
      if version.start_with?("2.")
        "ruby"
      else
        find_jruby
      end
    end
  end

  def self.find_jruby
    if mx?
      "#{JRUBY_DIR}/tool/jruby_mx"
    elsif jruby_eclipse?
      "#{JRUBY_DIR}/tool/jruby_eclipse"
    elsif ENV['RUBY_BIN']
      ENV['RUBY_BIN']
    else
      "#{JRUBY_DIR}/bin/jruby"
    end
  end

  def self.find_jruby_bin_dir
    # Make sure bin/ruby points to the right launcher
    ruby_symlink = "#{JRUBY_DIR}/bin/ruby"
    FileUtils.rm_f ruby_symlink
    File.symlink Utilities.find_jruby, ruby_symlink

    if jruby_eclipse? or mx?
      JRUBY_DIR + "/bin"
    else
      File.dirname(find_jruby)
    end
  end

  def self.find_repo(name)
    [JRUBY_DIR, "#{JRUBY_DIR}/.."].each do |dir|
      found = Dir.glob("#{dir}/#{name}*").first
      return File.expand_path(found) if found
    end
    raise "Can't find the #{name} repo - clone it into the repository directory or its parent"
  end

  def self.find_benchmark(benchmark)
    if File.exist?(benchmark)
      benchmark
    else
      File.join(find_repo('all-ruby-benchmarks'), benchmark)
    end
  end

  def self.find_gem(name)
    ["#{JRUBY_DIR}/lib/ruby/gems/shared/gems"].each do |dir|
      found = Dir.glob("#{dir}/#{name}*").first
      return File.expand_path(found) if found
    end

    [JRUBY_DIR, "#{JRUBY_DIR}/.."].each do |dir|
      found = Dir.glob("#{dir}/#{name}").first
      return File.expand_path(found) if found
    end
    raise "Can't find the #{name} gem - gem install it in this repository, or put it in the repository directory or its parent"
  end

  def self.git_branch
    @git_branch ||= `GIT_DIR="#{JRUBY_DIR}/.git" git rev-parse --abbrev-ref HEAD`.strip
  end

  def self.igv_running?
    `ps ax`.include?('idealgraphvisualizer')
  end

  def self.ensure_igv_running
    abort "I can't see IGV running - go to your checkout of Graal and run 'mx igv' in a separate shell, then run this command again" unless igv_running?
  end

  def self.jruby_version
    File.read("#{JRUBY_DIR}/VERSION").strip
  end

  def self.human_size(bytes)
    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1000**2
      "#{(bytes/1024.0).round(2)} KB"
    elsif bytes < 1000**3
      "#{(bytes/1024.0**2).round(2)} MB"
    elsif bytes < 1000**4
      "#{(bytes/1024.0**3).round(2)} GB"
    else
      "#{(bytes/1024.0**4).round(2)} TB"
    end
  end

  def self.log(tty_message, full_message)
    if STDERR.tty?
      STDERR.print tty_message unless tty_message.nil?
    else
      STDERR.print full_message unless full_message.nil?
    end
  end

end

module ShellUtils
  private

  def system_timeout(timeout, *args)
    begin
      pid = Process.spawn(*args)
    rescue SystemCallError
      return nil
    end

    begin
      Timeout.timeout timeout do
        Process.waitpid pid
        $?.exitstatus == 0
      end
    rescue Timeout::Error
      Process.kill('TERM', pid)
      nil
    end
  end

  def raw_sh(*args)
    options = args.last.is_a?(Hash) ? args.last : {}
    continue_on_failure = options.delete :continue_on_failure
    use_exec = options.delete :use_exec
    timeout = options.delete :timeout
    capture = options.delete :capture

    unless options.delete :no_print_cmd
      STDERR.puts "$ #{printable_cmd(args)}"
    end

    if use_exec
      result = exec(*args)
    elsif timeout
      result = system_timeout(timeout, *args)
    elsif capture
      out, err, status = Open3.capture3(*args)
      result = status.exitstatus == 0
    else
      result = system(*args)
    end

    if result
      if out && err
        [out, err]
      else
        true
      end
    elsif continue_on_failure
      false
    else
      status = $? unless capture
      $stderr.puts "FAILED (#{status}): #{printable_cmd(args)}"

      if capture
        $stderr.puts out
        $stderr.puts err
      end

      if status && status.exitstatus
        exit status.exitstatus
      else
        exit 1
      end
    end
  end

  def printable_cmd(args)
    env = {}
    if Hash === args.first
      env, *args = args
    end
    if Hash === args.last && args.last.empty?
      *args, options = args
    end
    env = env.map { |k,v| "#{k}=#{shellescape(v)}" }.join(' ')
    args = args.map { |a| shellescape(a) }.join(' ')
    env.empty? ? args : "#{env} #{args}"
  end

  def shellescape(str)
    return str unless str.is_a?(String)
    if str.include?(' ')
      if str.include?("'")
        require 'shellwords'
        Shellwords.escape(str)
      else
        "'#{str}'"
      end
    else
      str
    end
  end

  def replace_env_vars(string, env = ENV)
    string.gsub(/\$([A-Z_]+)/) {
      var = $1
      abort "You need to set $#{var}" unless env[var]
      env[var]
    }
  end

  def sh(*args)
    Dir.chdir(JRUBY_DIR) do
      raw_sh(*args)
    end
  end

  def mvn(*args)
    if args.first.is_a? Hash
      options = [args.shift]
    else
      options = []
    end

    args = ['-q', *args] unless VERBOSE

    sh *options, './mvnw', *args
  end

  def maven_options(*options)
    maven_options = []
    offline = options.delete('--offline')
    if offline
      maven_options.push "-Dmaven.repo.local=#{Utilities.find_repo('jruby-build-pack')}/maven"
      maven_options.push '--offline'
    end
    return [maven_options, options]
  end

  def mx(dir, *args)
    command = ['mx', '-p', dir]
    command.push *['--java-home', ENV['JVMCI_JAVA_HOME']] if ENV['JVMCI_JAVA_HOME']
    command.push *args
    sh *command
  end

  def mx_sulong(*args)
    abort "You need to set SULONG_HOME" unless SULONG_HOME
    mx SULONG_HOME, *args
  end

  def clang(*args)
    if ENV['USE_SYSTEM_CLANG']
      sh 'clang', *args
    else
      mx_sulong 'su-clang', *args
    end
  end

  def llvm_opt(*args)
    if ENV['USE_SYSTEM_CLANG']
      sh 'opt', *args
    else
      mx_sulong 'su-opt', *args
    end
  end

  def sulong_run(*args)
    mx_sulong 'su-run', *args
  end

  def sulong_link(*args)
    mx_sulong 'su-link', *args
  end

  def mspec(command, *args)
    env_vars = {}
    if command.is_a?(Hash)
      env_vars = command
      command, *args = args
    end

    if Utilities.mx?
      args.unshift "-ttool/jruby_mx"
    elsif Utilities.jruby_eclipse?
      args.unshift "-ttool/jruby_eclipse"
    end

    sh env_vars, Utilities.find_ruby, 'spec/mspec/bin/mspec', command, '--config', 'spec/truffle/truffle.mspec', *args
  end

  def newer?(input, output)
    return true unless File.exist? output
    File.mtime(input) > File.mtime(output)
  end
end

module Commands
  include ShellUtils

  def help
    puts <<-TXT.gsub(/^#{' '*6}/, '')
      jt checkout name                               checkout a different Git branch and rebuild
      jt bootstrap [options]                         run the build system\'s bootstrap phase
      jt build [options]                             build
      jt rebuild [options]                           clean and build
          truffle                                    build only the Truffle part, assumes the rest is up-to-date
          cexts [--no-openssl]                       build the cext backend (set SULONG_HOME and maybe USE_SYSTEM_CLANG)
          --offline                                  use the build pack to build offline
      jt clean                                       clean
      jt irb                                         irb
      jt rebuild                                     clean and build
      jt run [options] args...                       run JRuby with -X+T and args
          --graal         use Graal (set either GRAALVM_BIN or GRAAL_HOME and maybe JVMCI_JAVA_HOME)
          --js            add Graal.js to the classpath (set GRAAL_JS_JAR)
          --asm           show assembly (implies --graal)
          --server        run an instrumentation server on port 8080
          --igv           make sure IGV is running and dump Graal graphs after partial escape (implies --graal)
              --full      show all phases, not just up to the Truffle partial escape
          --jdebug        run a JDWP debug server on #{JDEBUG_PORT}
          --jexception[s] print java exceptions
          --exec          use exec rather than system
          --no-print-cmd  don\'t print the command
      jt e 14 + 2                                    evaluate an expression
      jt puts 14 + 2                                 evaluate and print an expression
      jt cextc directory clang-args                  compile the C extension in directory, with optional extra clang arguments
      jt test                                        run all mri tests, specs and integration tests (set SULONG_HOME, and maybe USE_SYSTEM_CLANG)
      jt test tck [--jdebug]                         run the Truffle Compatibility Kit tests
      jt test mri                                    run mri tests
      jt test specs                                  run all specs
      jt test specs fast                             run all specs except sub-processes, GC, sleep, ...
      jt test spec/ruby/language                     run specs in this directory
      jt test spec/ruby/language/while_spec.rb       run specs in this file
      jt test compiler                               run compiler tests (uses the same logic as --graal to find Graal)
          --no-java-cmd   don\'t set JAVACMD - rely on bin/jruby or RUBY_BIN to have Graal already
      jt test integration                            runs all integration tests
      jt test integration TESTS                      runs the given integration tests
      jt test gems                                   tests using gems
      jt test ecosystem [--offline]                  tests using the wider ecosystem such as bundler, Rails, etc
                                                         (when --offline it will not use rubygems.org)
      jt test cexts [--no-libxml --no-openssl]       run C extension tests
                                                         (implies --graal, where Graal needs to include Sulong, set SULONG_HOME to a built checkout of Sulong, and set GEM_HOME)
      jt test report :language                       build a report on language specs
                     :core                               (results go into test/target/mspec-html-report)
                     :library
      jt tag spec/ruby/language                      tag failing specs in this directory
      jt tag spec/ruby/language/while_spec.rb        tag failing specs in this file
      jt tag all spec/ruby/language                  tag all specs in this file, without running them
      jt untag spec/ruby/language                    untag passing specs in this directory
      jt untag spec/ruby/language/while_spec.rb      untag passing specs in this file
      jt metrics alloc [--json] ...                  how much memory is allocated running a program (use -Xclassic to test normal JRuby on this metric and others)
      jt metrics minheap ...                         what is the smallest heap you can use to run an application
      jt metrics time ...                            how long does it take to run a command, broken down into different phases
      jt tarball                                     build the and test the distribution tarball
      jt benchmark [options] args...                 run benchmark-interface (implies --graal)
          --no-graal       don\'t imply --graal
          note that to run most MRI benchmarks, you should translate them first with normal Ruby and cache the result, such as
              benchmark bench/mri/bm_vm1_not.rb --cache
              jt benchmark bench/mri/bm_vm1_not.rb --use-cache
      jt where repos ...                            find these repositories

      you can also put build or rebuild in front of any command

      recognised environment variables:

        RUBY_BIN                                     The JRuby+Truffle executable to use (normally just bin/jruby)
        GRAALVM_BIN                                  GraalVM executable (java command) to use
        GRAAL_HOME                                   Directory where there is a built checkout of the Graal compiler
                                                     (make sure mx is on your path and maybe set JVMCI_JAVA_HOME)
        JVMCI_JAVA_HOME                              The Java with JVMCI to use with GRAAL_HOME
        GRAALVM_RELEASE_BIN                          Default GraalVM executable when using a released version of Truffle (such as on master)
        GRAAL_HOME_TRUFFLE_HEAD                      Default Graal directory when using a snapshot version of Truffle (such as on truffle-head)
        SULONG_HOME                                  The Sulong source repository, if you want to run cextc
        USE_SYSTEM_CLANG                             Use the system clang rather than Sulong\'s when compiling C extensions
        GRAAL_JS_JAR                                 The location of trufflejs.jar
        SL_JAR                                       The location of truffle-sl.jar
        LIBXML_HOME, LIBXML_INCLUDE, LIBXML_LIB      The location of libxml2 (the directory containing include etc), and the direct include directory and library file
        OPENSSL_HOME, OPENSSL_INCLUDE, OPENSSL_LIB               ... OpenSSL ...
    TXT
  end

  def checkout(branch)
    sh 'git', 'checkout', branch
    rebuild
  end

  def bootstrap(*options)
    maven_options, other_options = maven_options(*options)
    mvn *maven_options, '-Pbootstrap-no-launcher'
  end

  def build(*options)
    maven_options, other_options = maven_options(*options)
    project = other_options.first
    env = VERBOSE ? {} : {'JRUBY_BUILD_MORE_QUIET' => 'true'}
    case project
    when 'truffle'
      mvn env, *maven_options, '-pl', 'truffle', 'package'
    when 'cexts'
      no_openssl = options.delete('--no-openssl')
      cextc "#{JRUBY_DIR}/truffle/src/main/c/cext"
      unless no_openssl
        cextc "#{JRUBY_DIR}/truffle/src/main/c/openssl",
          '-DRUBY_EXTCONF_H="extconf.h"',
          '-DJT_INT_VALUE=true',
          '-Werror=implicit-function-declaration'
      end
    when nil
      mvn env, *maven_options, 'package'
    else
      raise ArgumentError, project
    end
  end

  def clean
    mvn 'clean'
  end

  def irb(*args)
    run(*%w[-S irb], *args)
  end

  def rebuild
    FileUtils.cp("#{JRUBY_DIR}/bin/jruby.bash", "#{JRUBY_DIR}/bin/jruby")
    clean
    build
  end

  def run(*args)
    env_vars = args.first.is_a?(Hash) ? args.shift : {}

    jruby_args = [
      '-X+T',
      "-Xtruffle.core.load_path=#{JRUBY_DIR}/truffle/src/main/ruby",
      '-Xtruffle.graal.warn_unless=false'
    ]

    if ENV['JRUBY_OPTS'] && ENV['JRUBY_OPTS'].include?('-Xclassic')
      jruby_args.delete '-X+T'
    end

    {
      '--asm' => '--graal',
      '--igv' => '--graal'
    }.each_pair do |arg, dep|
      args.unshift dep if args.include?(arg)
    end

    if args.delete('--graal')
      javacmd, javacmd_options = Utilities.find_graal_javacmd_and_options
      env_vars["JAVACMD"] = javacmd
      jruby_args.push *javacmd_options
      jruby_args.delete('-Xtruffle.graal.warn_unless=false')
    end

    if args.delete('--js')
      jruby_args << '-J-cp'
      jruby_args << Utilities.find_graal_js
    end

    if args.delete('--asm')
      jruby_args += %w[-J-XX:+UnlockDiagnosticVMOptions -J-XX:CompileCommand=print,*::callRoot]
    end

    if args.delete('--jdebug')
      jruby_args << JDEBUG
    end

    if args.delete('--jexception') || args.delete('--jexceptions')
      jruby_args << JEXCEPTION
    end

    if args.delete('--server')
      jruby_args += %w[-Xtruffle.instrumentation_server_port=8080]
    end

    if args.delete('--profile')
      v = Utilities.truffle_version
      jruby_args << "-J-Xbootclasspath/a:#{M2_REPO}/com/oracle/truffle/truffle-debug/#{v}/truffle-debug-#{v}.jar"
      jruby_args << "-J-Dtruffle.profiling.enabled=true"
    end

    if args.delete('--igv')
      warn "warning: --igv might not work on master - if it does not, use truffle-head instead which builds against latest graal" if Utilities.git_branch == 'master'
      Utilities.ensure_igv_running
      if args.delete('--full')
        jruby_args += %w[-J-G:Dump=Truffle]
      else
        jruby_args += %w[-J-G:Dump=TrufflePartialEscape]
      end
    end

    if args.delete('--no-print-cmd')
      args << { no_print_cmd: true }
    end

    if args.delete('--exec')
      args << { use_exec: true }
    end

    raw_sh env_vars, Utilities.find_jruby, *jruby_args, *args
  end
  alias ruby run

  def e(*args)
    run '-e', args.join(' ')
  end

  def command_puts(*args)
    e 'puts begin', *args, 'end'
  end

  def command_p(*args)
    e 'p begin', *args, 'end'
  end

  def cextc(cext_dir, *clang_opts)
    abort "You need to set SULONG_HOME" unless SULONG_HOME

    # Ensure ruby.su is up-to-date
    ruby_cext_api = "#{JRUBY_DIR}/truffle/src/main/c/cext"
    ruby_c = "#{JRUBY_DIR}/truffle/src/main/c/cext/ruby.c"
    ruby_h = "#{JRUBY_DIR}/lib/ruby/truffle/cext/ruby.h"
    ruby_su = "#{JRUBY_DIR}/lib/ruby/truffle/cext/ruby.su"
    if cext_dir != ruby_cext_api and (newer?(ruby_h, ruby_su) or newer?(ruby_c, ruby_su))
      puts "Compiling outdated ruby.su"
      cextc ruby_cext_api
    end

    config_file = File.join(cext_dir, CEXTC_CONF_FILE)
    unless File.exist?(config_file)
      abort "There is no #{CEXTC_CONF_FILE} in #{cext_dir} at the moment - I don't know how to build it"
    end

    config = YAML.load_file(config_file)
    config_src = config['src']

    src = replace_env_vars(config['src'])
    src = File.expand_path(src, cext_dir)
    src = Dir[src]

    config_cflags = config['cflags'] || ''
    config_cflags = replace_env_vars(config_cflags)
    config_cflags = config_cflags.split
    # Expand include paths
    config_cflags.map! { |cflag|
      if cflag.start_with? '-I'
        inc = File.expand_path(cflag[2..-1], cext_dir)
        "-I#{inc}"
      else
        cflag
      end
    }

    out = File.expand_path(config['out'], cext_dir)

    lls = []

    src.each do |src|
      ll = File.join(File.dirname(out), File.basename(src, '.*') + '.ll')

      clang "-I#{SULONG_HOME}/include", '-Ilib/ruby/truffle/cext', '-S', '-emit-llvm', *config_cflags, *clang_opts, src, '-o', ll
      llvm_opt '-S', '-mem2reg', ll, '-o', ll

      lls.push ll
    end

    config_libs = config['libs'] || ''
    config_libs = replace_env_vars(config_libs)
    config_libs = config_libs.split(' ')

    if MAC
      config_libs.each do |lib|
        if lib.include?('.so')
          lib['.so'] = '.dylib'
        end
      end
    end

    config_libs = config_libs.flat_map { |l| ['-l', l] }

    sulong_link '-o', out, *config_libs, *lls
  end

  def test(*args)
    path, *rest = args

    case path
    when nil
      test_tck
      test_specs('run')
      # test_mri # TODO (pitr-ch 29-Mar-2016): temporarily disabled since it uses refinements
      test_integration
      test_gems
      test_ecosystem 'HAS_REDIS' => 'true'
      test_compiler
      test_cexts
    when 'compiler' then test_compiler(*rest)
    when 'cexts' then test_cexts(*rest)
    when 'report' then test_report(*rest)
    when 'integration' then test_integration({}, *rest)
    when 'gems' then test_gems({}, *rest)
    when 'ecosystem' then test_ecosystem({}, *rest)
    when 'specs' then test_specs('run', *rest)
    when 'tck' then
      args = []
      if rest.include? '--jdebug'
        args << JDEBUG_TEST
      end
      test_tck *args
    when 'mri' then test_mri(*rest)
    else
      if File.expand_path(path).start_with?("#{JRUBY_DIR}/test")
        test_mri(*args)
      else
        test_specs('run', *args)
      end
    end
  end

  def test_mri(*args)
    env_vars = {
      "EXCLUDES" => "test/mri/excludes_truffle"
    }
    jruby_args = %w[-J-Xmx2G -Xtruffle.exceptions.print_java]

    if args.empty?
      args = File.readlines("#{JRUBY_DIR}/test/mri_truffle.index").grep(/^[^#]\w+/).map(&:chomp)
    end

    command = %w[test/mri/runner.rb -v --color=never --tty=no -q]
    run(env_vars, *jruby_args, *command, *args)
  end
  private :test_mri

  def test_compiler(*args)
    jruby_opts = []
    jruby_opts << '-Xtruffle.graal.warn_unless=false'

    if ENV['GRAAL_JS_JAR']
      jruby_opts << '-J-cp'
      jruby_opts << Utilities.find_graal_js
    end

    jruby_opts << '-Xtruffle.exceptions.print_java=true'

    no_java_cmd = args.delete('--no-java-cmd')

    unless no_java_cmd
      javacmd, javacmd_options = Utilities.find_graal_javacmd_and_options
      jruby_opts.push *javacmd_options
    end

    env_vars = {}
    env_vars["JAVACMD"] = javacmd unless no_java_cmd
    env_vars["JRUBY_OPTS"] = jruby_opts.join(' ')
    env_vars["PATH"] = "#{Utilities.find_jruby_bin_dir}:#{ENV["PATH"]}"

    Dir["#{JRUBY_DIR}/test/truffle/compiler/*.sh"].each do |test_script|
      sh env_vars, test_script
    end
  end
  private :test_compiler

  def test_cexts(*args)
    no_libxml = args.delete('--no-libxml')
    no_openssl = args.delete('--no-openssl')

    # Test that we can compile and run some basic C code that uses libxml and openssl

    unless no_libxml
      clang '-S', '-emit-llvm', "-I#{LIBXML_INCLUDE}", 'test/truffle/cexts/xml/main.c', '-o', 'test/truffle/cexts/xml/main.ll'
      out, _ = sulong_run("-l#{LIBXML_LIB}", 'test/truffle/cexts/xml/main.ll', {capture: true})
      raise unless out == "7\n"
    end

    unless no_openssl
      clang '-S', '-emit-llvm', "-I#{OPENSSL_INCLUDE}", 'test/truffle/cexts/xopenssl/main.c', '-o', 'test/truffle/cexts/xopenssl/main.ll'
      out, _ = sulong_run("-l#{OPENSSL_LIB}", 'test/truffle/cexts/xopenssl/main.ll', {capture: true})
      raise unless out == "5d41402abc4b2a76b9719d911017c592\n"
    end

    # Test that we can run those same test when they're build as a .su and we load the code and libraries from that

    unless no_libxml
      sulong_link '-o', 'test/truffle/cexts/xml/main.su', '-l', "#{LIBXML_LIB}", 'test/truffle/cexts/xml/main.ll'
      out, _ = sulong_run('test/truffle/cexts/xml/main.su', {capture: true})
      raise unless out == "7\n"
    end

    unless no_openssl
      sulong_link '-o', 'test/truffle/cexts/xopenssl/main.su', '-l', "#{OPENSSL_LIB}", 'test/truffle/cexts/xopenssl/main.ll'
      out, _ = sulong_run('test/truffle/cexts/xopenssl/main.su', {capture: true})
      raise unless out == "5d41402abc4b2a76b9719d911017c592\n"
    end

    # Test that we can compile and run some very basic C extensions

    begin
      output_file = 'cext-output.txt'
      ['minimum', 'method', 'module', 'globals', 'xml', 'xopenssl'].each do |gem_name|
        next if gem_name == 'xml' && no_libxml
        next if gem_name == 'xopenssl' && no_openssl
        dir = "#{JRUBY_DIR}/test/truffle/cexts/#{gem_name}"
        cextc dir
        name = File.basename(dir)
        next if gem_name == 'globals' # globals is excluded just for running
        run '--graal', "-I#{dir}/lib", "#{dir}/bin/#{name}", :out => output_file
        unless File.read(output_file) == File.read("#{dir}/expected.txt")
          abort "c extension #{dir} didn't work as expected"
        end
      end
    ensure
      File.delete output_file rescue nil
    end

    # Test that we can compile and run some real C extensions

    [
        ['oily_png', ['chunky_png-1.3.6', 'oily_png-1.2.0'], ['oily_png']],
        ['psd_native', ['chunky_png-1.3.6', 'oily_png-1.2.0', 'bindata-2.3.1', 'hashie-3.4.4', 'psd-enginedata-1.1.1', 'psd-2.1.2', 'psd_native-1.1.3'], ['oily_png', 'psd_native']],
        ['nokogiri', [], ['nokogiri']],
        ['ruby-argon2', [], [], "#{ENV['GEM_HOME']}/bundler/gems/ruby-argon2-5a527075e88b"]
    ].each do |gem_name, dependencies, libs, gem_root|
      next if gem_name == 'nokogiri' # nokogiri totally excluded
      next if gem_name == 'nokogiri' && no_libxml
      unless gem_root and File.exist?(File.join(gem_root, CEXTC_CONF_FILE))
        gem_root = "#{JRUBY_DIR}/test/truffle/cexts/#{gem_name}"
      end
      cextc gem_root, '-Werror=implicit-function-declaration'
      next if gem_name == 'psd_native' # psd_native is excluded just for running
      run '--graal',
        *dependencies.map { |d| "-I#{ENV['GEM_HOME']}/gems/#{d}/lib" },
        *libs.map { |l| "-I#{JRUBY_DIR}/test/truffle/cexts/#{l}/lib" },
        "#{JRUBY_DIR}/test/truffle/cexts/#{gem_name}/test.rb", gem_root
    end
  end
  private :test_cexts

  def test_report(component)
    test 'specs', '--truffle-formatter', component
    sh 'ant', '-f', 'spec/truffle/buildTestReports.xml'
  end
  private :test_cexts

  def test_integration(env={}, *args)
    env_vars   = env
    jruby_opts = []

    jruby_opts << '-Xtruffle.graal.warn_unless=false'

    if ENV['GRAAL_JS_JAR']
      jruby_opts << '-J-cp'
      jruby_opts << Utilities.find_graal_js
    end

    if ENV['SL_JAR']
      jruby_opts << '-J-cp'
      jruby_opts << Utilities.find_sl
    end

    env_vars["JRUBY_OPTS"] = jruby_opts.join(' ')

    env_vars["PATH"]       = "#{Utilities.find_jruby_bin_dir}:#{ENV["PATH"]}"
    tests_path             = "#{JRUBY_DIR}/test/truffle/integration"
    single_test            = !args.empty?
    test_names             = single_test ? '{' + args.join(',') + '}' : '*'

    Dir["#{tests_path}/#{test_names}.sh"].each do |test_script|
      sh env_vars, test_script
    end
  end
  private :test_integration

  def test_gems(env={}, *args)
    env_vars   = env
    jruby_opts = []

    jruby_opts << '-Xtruffle.graal.warn_unless=false'

    if ENV['GRAAL_JS_JAR']
      jruby_opts << '-J-cp'
      jruby_opts << Utilities.find_graal_js
    end

    env_vars["JRUBY_OPTS"] = jruby_opts.join(' ')

    env_vars["PATH"]       = "#{Utilities.find_jruby_bin_dir}:#{ENV["PATH"]}"
    tests_path             = "#{JRUBY_DIR}/test/truffle/gems"
    single_test            = !args.empty?
    test_names             = single_test ? '{' + args.join(',') + '}' : '*'

    Dir["#{tests_path}/#{test_names}.sh"].each do |test_script|
      next if test_script.end_with?('/install-gems.sh')
      sh env_vars, test_script
    end
  end
  private :test_gems

  def test_ecosystem(env={}, *args)
    env_vars   = env
    jruby_opts = []

    jruby_opts << '-Xtruffle.graal.warn_unless=false'

    env_vars["JRUBY_OPTS"] = jruby_opts.join(' ')

    unless File.exist? "#{JRUBY_DIR}/../jruby-truffle-gem-test-pack/gem-testing"
      raise 'missing ../jruby-truffle-gem-test-pack/gem-testing directory'
    end

    env_vars["PATH"]       = "#{Utilities.find_jruby_bin_dir}:#{ENV["PATH"]}"
    tests_path             = "#{JRUBY_DIR}/test/truffle/ecosystem"
    single_test            = !args.empty?
    test_names             = single_test ? '{' + args.join(',') + '}' : '*'

    Dir["#{tests_path}/#{test_names}.sh"].each do |test_script|
      sh env_vars, test_script
    end
  end
  private :test_ecosystem

  def test_specs(command, *args)
    env_vars = {}
    options = []

    case command
    when 'run'
      options += %w[--excl-tag fails]
    when 'tag'
      options += %w[--add fails --fail]
    when 'untag'
      options += %w[--del fails --pass]
      command = 'tag'
    when 'tag_all'
      options += %w[--unguarded --all --dry-run --add fails]
      command = 'tag'
    else
      raise command
    end

    if args.first == 'fast'
      args.shift
      options += %w[--excl-tag slow]
      options << "-T-Xtruffle.backtraces.limit=4" unless args[-2..-1] == %w[-t ruby]
    end

    if args.delete('--graal')
      javacmd, javacmd_options = Utilities.find_graal_javacmd_and_options
      env_vars["JAVACMD"] = javacmd
      options.concat javacmd_options.map { |o| "-T#{o}" }
    end

    if args.delete('--jdebug')
      options << "-T#{JDEBUG}"
    end

    if args.delete('--jexception') || args.delete('--jexceptions')
      options << "-T#{JEXCEPTION}"
    end

    if args.delete('--truffle-formatter')
      options += %w[--format spec/truffle/truffle_formatter.rb]
    end

    if ENV['CI']
      # Need lots of output to keep Travis happy
      options += %w[--format specdoc]
    end

    mspec env_vars, command, *options, *args
  end
  private :test_specs

  def test_tck(*args)
    env = {'JRUBY_BUILD_MORE_QUIET' => 'true'}
    mvn env, *args, '-Ptck'
  end
  private :test_tck

  def tag(path, *args)
    return tag_all(*args) if path == 'all'
    test_specs('tag', path, *args)
  end

  # Add tags to all given examples without running them. Useful to avoid file exclusions.
  def tag_all(*args)
    test_specs('tag_all', *args)
  end
  private :tag_all

  def untag(path, *args)
    puts
    puts "WARNING: untag is currently not very reliable - run `jt test #{[path,*args] * ' '}` after and manually annotate any new failures"
    puts
    test_specs('untag', path, *args)
  end

  def metrics(command, *args)
    trap(:INT) { puts; exit }
    args = args.dup
    case command
    when 'alloc'
      metrics_alloc *args
    when 'minheap'
        metrics_minheap *args
    when 'time'
        metrics_time *args
    else
      raise ArgumentError, command
    end
  end

  def metrics_alloc(*args)
    use_json = args.delete '--json'
    samples = []
    METRICS_REPS.times do
      Utilities.log '.', "sampling\n"
      out, err = run '-Xtruffle.metrics.memory_used_on_exit=true', '-J-verbose:gc', *args, {capture: true, no_print_cmd: true}
      samples.push memory_allocated(out+err)
    end
    Utilities.log "\n", nil
    range = samples.max - samples.min
    error = range / 2
    median = samples.min + error
    human_readable = "#{Utilities.human_size(median)} ± #{Utilities.human_size(error)}"
    if use_json
      puts JSON.generate({
          samples: samples,
          median: median,
          error: error,
          human: human_readable
      })
    else
      puts human_readable
    end
  end

  def memory_allocated(trace)
    allocated = 0
    trace.lines do |line|
      case line
      when /(\d+)K->(\d+)K/
        before = $1.to_i * 1024
        after = $2.to_i * 1024
        collected = before - after
        allocated += collected
      when /^allocated (\d+)$/
        allocated += $1.to_i
      end
    end
    allocated
  end

  def metrics_minheap(*args)
    use_json = args.delete '--json'
    heap = 10
    Utilities.log '>', "Trying #{heap} MB\n"
    until can_run_in_heap(heap, *args)
      heap += 10
      Utilities.log '>', "Trying #{heap} MB\n"
    end
    heap -= 9
    heap = 1 if heap == 0
    successful = 0
    loop do
      if successful > 0
        Utilities.log '?', "Verifying #{heap} MB\n"
      else
        Utilities.log '+', "Trying #{heap} MB\n"
      end
      if can_run_in_heap(heap, *args)
        successful += 1
        break if successful == METRICS_REPS
      else
        heap += 1
        successful = 0
      end
    end
    Utilities.log "\n", nil
    human_readable = "#{heap} MB"
    if use_json
      puts JSON.generate({
          min: heap,
          human: human_readable
      })
    else
      puts human_readable
    end
  end

  def can_run_in_heap(heap, *command)
    run("-J-Xmx#{heap}M", *command, {err: '/dev/null', out: '/dev/null', no_print_cmd: true, continue_on_failure: true, timeout: 60})
  end

  def metrics_time(*args)
    use_json = args.delete '--json'
    samples = []
    METRICS_REPS.times do
      Utilities.log '.', "sampling\n"
      start = Time.now
      out, err = run '-Xtruffle.metrics.time=true', *args, {capture: true, no_print_cmd: true}
      finish = Time.now
      samples.push get_times(err, finish - start)
    end
    Utilities.log "\n", nil
    results = {}
    samples[0].each_key do |region|
      region_samples = samples.map { |s| s[region] }
      mean = region_samples.inject(:+) / samples.size
      human = "#{region.strip} #{mean.round(2)} s"
      results[region] = {
          samples: region_samples,
          mean: mean,
          human: human
      }
      if use_json
        file = STDERR
      else
        file = STDOUT
      end
      file.puts region[/\s*/] + human
    end
    if use_json
      puts JSON.generate(Hash[results.map { |key, values| [key.strip, values] }])
    end
  end

  def get_times(trace, total)
    start_times = {}
    times = {}
    depth = 1
    accounted_for = 0
    trace.lines do |line|
      if line =~ /^([a-z\-]+) (\d+\.\d+)$/
        region = $1
        time = $2.to_f
        if region.start_with? 'before-'
          depth += 1
          region = (' ' * depth + region['before-'.size..-1])
          start_times[region] = time
        elsif region.start_with? 'after-'
          region = (' ' * depth + region['after-'.size..-1])
          depth -= 1
          elapsed = time - start_times[region]
          times[region] = elapsed
          accounted_for += elapsed if depth == 2
        end
      end
    end
    times[' jvm'] = total - times['  main']
    times['total'] = total
    times['unaccounted'] = total - accounted_for if times['    load-core']
    times
  end

  def tarball(*options)
    maven_options, other_options = maven_options(*options)
    mvn *maven_options, '-Pdist'
    generated_file = "#{JRUBY_DIR}/maven/jruby-dist/target/jruby-dist-#{Utilities.jruby_version}-bin.tar.gz"
    final_file = "#{JRUBY_DIR}/jruby-bin-#{Utilities.jruby_version}.tar.gz"
    FileUtils.copy generated_file, final_file
    FileUtils.copy "#{generated_file}.sha256", "#{final_file}.sha256"
    sh 'test/truffle/tarball.sh', final_file
  end

  def benchmark(*args)
    args.map! do |a|
      if a.include?('.rb')
        benchmark = Utilities.find_benchmark(a)
        raise 'benchmark not found' unless File.exist?(benchmark)
        benchmark
      else
        a
      end
    end

    run_args = []
    run_args.push '--graal' unless args.delete('--no-graal') || args.include?('list')
    run_args.push '-J-G:+TruffleCompilationExceptionsAreFatal'
    run_args.push "-I#{Utilities.find_gem('deep-bench')}/lib" rescue nil
    run_args.push "-I#{Utilities.find_gem('benchmark-ips')}/lib" rescue nil
    run_args.push "#{Utilities.find_gem('benchmark-interface')}/bin/benchmark"
    run_args.push *args
    run *run_args
  end

  def where(*args)
    case args.shift
    when 'repos'
      args.each do |a|
        puts Utilities.find_repo(a)
      end
    end
  end

  def check_ambiguous_arguments
    ENV.delete "JRUBY_ECLIPSE" # never run from the Eclipse launcher here
    clean
    # modify pom
    pom = "#{JRUBY_DIR}/truffle/pom.rb"
    contents = File.read(pom)
    contents.gsub!(/^(\s+)'source'\s*=>.+'1.7'.+,\n\s+'target'\s*=>.+\s*'1.7.+,\n/) do
      indent = $1
      $&.gsub("1.7", "1.8") + "#{indent}'fork' => 'true',\n"
    end
    contents.sub!(/^(\s+)('-J-Dfile.encoding=UTF-8')(.+\n)(?!\1'-parameters')/) do
      "#{$1}#{$2},\n#{$1}'-parameters'#{$3}"
    end
    File.write pom, contents

    build
    run({ "TRUFFLE_CHECK_AMBIGUOUS_OPTIONAL_ARGS" => "true" }, '-e', 'exit')
  end

end

class JT
  include Commands

  def main(args)
    args = args.dup

    if args.empty? or %w[-h -help --help].include? args.first
      help
      exit
    end

    case args.first
    when "rebuild"
      send(args.shift)
    when "build"
      command = [args.shift]
      while ['truffle', 'cexts', '--offline', '--no-openssl'].include?(args.first)
        command << args.shift
      end
      send(*command)
    end

    return if args.empty?

    commands = Commands.public_instance_methods(false).map(&:to_s)

    command, *rest = args
    command = "command_#{command}" if %w[p puts].include? command

    abort "no command matched #{command.inspect}" unless commands.include?(command)

    begin
      send(command, *rest)
    rescue
      puts "Error during command: #{args*' '}"
      raise $!
    end
  end
end

JT.new.main(ARGV)
