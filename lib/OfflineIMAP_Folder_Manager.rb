#!/usr/bin/ruby
#

####
#
# OfflineIMAP Folder Manager
#
# This script will create your desired folder on the remote email server.
#
# (c) 2010-2011, Bjoern Rennhak
#
############


# = Libraries
require 'optparse' 
require 'optparse/time' 
require 'pty'
require 'expect'
require 'ostruct'


class OfflineIMAPFolderManager # {{{

  def initialize options = nil # {{{
    @options                    = options

    @config                     = OpenStruct.new
    @config.initial_delay       = 2
    @config.username            = nil
    @config.hostname            = nil

    unless( options.nil? )
      message :success, "Starting #{__FILE__} run"
      message :info, "Colorizing output as requested" if( @options.colorize )

      ####
      #
      # Main Control Flow
      #
      ##########

      # Ruby PTY class responses wrapped in an Ostruct -> @session.reader ; @session.writer ; @session.pid 
      if( @options.username.nil? or @options.hostname.nil? )
        raise ArgumentError, "You need to supply a username and a hostname to login via SSH."
      else
        @config.username        = @options.username
        @config.hostname        = @options.hostname
        @config.vserver_name    = @options.vserver_name
        @session                = login
      end

      # FIXME - These patterns are NG
      @login_pattern             = %r{^Last login.*$}i
      # @prompt_pattern            = %r{^.*root\]%}i
      @prompt_pattern            = /[%|#]/
      # @prompt_pattern_vserver    = %r{.*:/#}i
      @prompt_pattern_vserver    = /[%|#]/

      @session.writer.sync      = true

      unless( @options.vserver_name.nil? )
        message :info, "Logging into a VServer (#{@config.vserver_name.to_s})"
        @prompt_pattern          = @prompt_pattern_vserver
        send "", "vserver #{@options.vserver_name.to_s} enter"
      end

      unless( @options.commands.nil? )
        @options.commands.each do |cmd|
          printf( "Command: %-10s | %-50s\n", cmd.to_s, receive( @prompt_pattern, cmd.to_s ).join(", ") )
        end # of @options.commands.each 
      end # of unless( @options.commands.nil

      if( @options.create_maildir_directory )
        base_directory, email_address, create_directory_name, chown_to_user = @options.create_maildir_directory
        create_maildir_directory( base_directory, email_address, create_directory_name, chown_to_user )
      end

      mailq if( @options.mailq )

      logout unless( @session.reader.nil? and @session.writer.nil? )

      message :success, "Finished #{__FILE__} run"
    end # of unless( options.nil? )

  end # of def initialize }}}


  # = The function mailq checks the Postfix mail queue if there are mails or not.
  def mailq # {{{
    send( @prompt_pattern, "mailq > /tmp/mailq.tmp" )
    sleep 1
    mailq_output = receive( @prompt_pattern, "cat /tmp/mailq.tmp" )

    if( mailq_output.include?( "Mail queue is empty" ) )
      # everything is ok
      puts "Mail queue is empty"
    else
      # there might be a problem, but we need to make sure it really is a problem
      sleep 5
      send( @prompt_pattern, "mailq > /tmp/mailq.tmp" )
      mailq_output = receive( @prompt_pattern, "cat /tmp/mailq.tmp" )

      if( mailq_output.include?( "Mail queue is empty" ) )
        puts "Mail queue is empty"
      else
        puts "Mail queue is **NOT** empty"
      end
    end
  end # }}}


  # = Create MailDir type Directory on Server. This expects that on the server the maildirmake command is available.
  # @param go_to_directory, create_directory_name, chown_to_user
  def create_maildir_directory base_directory, email_address, create_directory_name, chown_to_user # {{{
    message :info, "Create maildir directory called"

    # turn e.g. name@example.com into example.com/name
    path              = File.join( *( email_address.to_s.split( "@" ).reverse.collect { |i| i.strip } ) )

    sleep 1
    send( @prompt_pattern, "zsh" )
    sleep 1
    send( @prompt_pattern, "cd #{base_directory.to_s}" )
    sleep 1
    send( @prompt_pattern, "cd #{path.to_s}" )
    sleep 1
    send( @prompt_pattern, "maildirmake #{create_directory_name.to_s}" )
    sleep 1
    send( @prompt_pattern, "chown -R #{chown_to_user}: #{create_directory_name.to_s}" )
    sleep 1
  end # of def create_directory }}}


  # = The function 'parse_cmd_arguments' takes a number of arbitrary commandline arguments and parses them into a proper data structure via optparse
  # @param args Ruby's STDIN.ARGS from commandline
  # @returns Ruby optparse package options hash object
  def parse_cmd_arguments( args ) # {{{

    options               = OpenStruct.new

    # Define default options
    options.debug         = false
    options.colorize      = false
    options.username      = nil
    options.hostname      = nil
    options.vserver_name  = nil
    options.mailq         = nil
    options.quiet         = false
    options.commands      = []
    pristine_options      = options.dup

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: #{__FILE__.to_s} [options]"

      opts.separator ""
      opts.separator "General options:"


      #opts.separator ""
      #opts.separator "Specific options:"

      # Set of arguments
      opts.on( "-r", "--run CMD", "Run this command on server via SSH" ) do |r|
        options.commands << r
      end

      opts.on( "-u", "--username USERNAME", "Use the USERNAME to login to the supplied HOSTNAME via SSH" ) do |u|
        options.username = u
      end

      opts.on( "-s", "--server HOSTNAME", "Use the HOSTNAME to login via SSH" ) do |h|
        options.hostname = h
      end

      opts.on( "-v", "--vserver NAME", "Use the virtual server NAME to login to a Vserver cage after SSH login" ) do |v|
        options.vserver_name = v
      end

      opts.on( "-m", "--mailq", "Check Postfix Mail Queue (mailq)" ) do |m|
        options.mailq = m
      end

      opts.on( "--create-maildir base_dir, email_address, folder_name, chown_username", Array, "Create MailDir on Server via SSH. Supply: e.g. \"base_dir, email_address, folder_name, chown_username\".\n\t\t\t\t     You might want to start the folder_name with a dot if you use IMAP." ) do |list|
        options.create_maildir_directory = list
      end

      # Boolean switch.
      opts.on( "", "--verbose", "Run verbosely") do |v|
        options.verbose = v
      end

      # Boolean switch.
      opts.on( "-q", "--quiet", "Run quietly, don't output much") do |q|
        options.quiet = q
      end

      # Boolean switch.
      opts.on( "--debug", "Print verbose output and more debugging") do |d|
        options.debug = d
      end

      opts.separator ""
      opts.separator "Common options:"

      # Boolean switch.
      opts.on( "-c", "--colorize", "Colorizes the output of the script for easier reading") do |c|
        options.colorize = c
      end

      opts.on_tail( "-h", "--help", "Show this message") do
        puts opts
        exit
      end

      # Another typical switch to print the version.
      opts.on_tail("--version", "Show version") do
        puts OptionParser::Version.join('.')
        exit
      end
    end

    opts.parse!(args)

    # Show opts if we have no cmd arguments
    if( options == pristine_options )
      puts opts
      exit
    end

    options
  end # of parse_cmd_arguments }}}


  # = The function colorize takes a message and wraps it into standard color commands such as for bash.
  # @param color String, of the colorname in plain english. e.g. "LightGray", "Gray", "Red", "BrightRed"
  # @param message String, of the message which should be wrapped
  # @returns String, colorized message string
  # WARNING: Might not work for your terminal
  # FIXME: Implement bold behavior
  # FIXME: This method is currently b0rked
  def colorize color, message # {{{

    # Black       0;30     Dark Gray     1;30
    # Blue        0;34     Light Blue    1;34
    # Green       0;32     Light Green   1;32
    # Cyan        0;36     Light Cyan    1;36
    # Red         0;31     Light Red     1;31
    # Purple      0;35     Light Purple  1;35
    # Brown       0;33     Yellow        1;33
    # Light Gray  0;37     White         1;37

    colors  = { 
      "Gray"        => "\e[1;30m",
      "LightGray"   => "\e[0;37m",
      "Cyan"        => "\e[0;36m",
      "LightCyan"   => "\e[1;36m",
      "Blue"        => "\e[0;34m",
      "LightBlue"   => "\e[1;34m",
      "Green"       => "\e[0;32m",
      "LightGreen"  => "\e[1;32m",
      "Red"         => "\e[0;31m",
      "LightRed"    => "\e[1;31m",
      "Purple"      => "\e[0;35m",
      "LightPurple" => "\e[1;35m",
      "Brown"       => "\e[0;33m",
      "Yellow"      => "\e[1;33m",
      "White"       => "\e[1;37m"
    }
    nocolor    = "\e[0m"

    colors[ color ] + message + nocolor
  end # of def colorize }}}


  # = The function message will take a message as argument as well as a level (e.g. "info", "ok", "error", "question", "debug") which then would print 
  #   ( "(--) msg..", "(II) msg..", "(EE) msg..", "(??) msg..")
  # @param level Ruby symbol, can either be :info, :success, :error or :question
  # @param msg String, which represents the message you want to send to stdout (info, ok, question) stderr (error)
  # Helpers: colorize
  def message level, msg # {{{

    symbols = {
      :info      => "(--)",
      :success   => "(II)",
      :error     => "(EE)",
      :question  => "(??)",
			:debug		 => "(++)"
    }

    raise ArugmentError, "Can't find the corresponding symbol for this message level (#{level.to_s}) - is the spelling wrong?" unless( symbols.key?( level )  )

    unless( @options.quiet )

      if( @options.colorize )
        if( level == :error )
          STDERR.puts colorize( "LightRed", "#{symbols[ level ].to_s} #{msg.to_s}" )
        else
          STDOUT.puts colorize( "LightGreen", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :success )
          STDOUT.puts colorize( "LightCyan", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :question )
          STDOUT.puts colorize( "Brown", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :info )
          STDOUT.puts colorize( "LightBlue", "#{symbols[ level ].to_s} #{msg.to_s}" ) if( level == :debug and @options.debug )
        end
      else
        if( level == :error )
          STDERR.puts "#{symbols[ level ].to_s} #{msg.to_s}" 
        else
          STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :success )
          STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :question )
          STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :info )
          STDOUT.puts "#{symbols[ level ].to_s} #{msg.to_s}" if( level == :debug and @options.debug )
        end
      end # of if( @config.colorize )

    end

  end # of def message }}}



  # = The function debug turns ruby core PTY debuggin on and off
  # @param boolean Boolean, true for debug output, false for not
  def debug boolean = false # {{{
    $expect_verbose = boolean
  end # of def debug }}}


  # = The login function will connect to your server via SSH
  # @param hostname String, which represents the host we want to connect to
  # @param username String, which represents the username of the host we want to connect to
  # @returns OStruct, containing reader, writer and pid object of the PTY class. (e.g. ostruct.reader etc.)
  def login hostname = @config.hostname, username = @config.username # {{{
    o                           = OpenStruct.new    # holds our PTY objects

    uri                         = "ssh #{username}@#{hostname}"
    o.reader, o.writer, o.pid   = PTY.spawn( uri )

    o
  end # of def login }}}


  # = The logout function will take a valid NET::SSH object and close it properly - thus logging out from the established connection.
  # @param session OStruct object with reader, writer, pid of instanciated PTY object
  def logout session = @session # {{{
    %w[reader writer].each { |o| eval( "session.#{o}.close" ) }
  end # }}}


  # = The function send is a convenience wrapper around the execute function.
  #   Its only purpose is to send an extra output = false to execute and pass along
  #   the other arguments.
  # @param if_pattern String, representing regular expression guard of first session.reader (to make sure we are at the prompt we want)
  # @param command String, representing the command we want to issue
  # @param session OStruct containing the PTY objects @session.reader, @session.writer, @session.pid
  # @note This is only necessary since the PTY reader event to capture text with certain commands causes deadlocks.
  def send if_pattern, command, session = @session # {{{
    execute if_pattern, command, false, session
  end # of def send }}}


  # = The function receive is a convenience wrapper around the execute function.
  #   Its only purpose is to send an extra output = true to execute and pass along
  #   the other arguments.
  # @param if_pattern String, representing regular expression guard of first session.reader (to make sure we are at the prompt we want)
  # @param command String, representing the command we want to issue
  # @param session OStruct containing the PTY objects @session.reader, @session.writer, @session.pid
  # @note This is only necessary since the PTY reader event to capture text with certain commands causes deadlocks.
  def receive if_pattern, command, session = @session # {{{
    execute if_pattern, command, true, session
  end # of def receive }}}


  # = The function execute checks if_pattern with current reader.exepect, calls command (writer.puts) and returns output
  # @param if_pattern String, representing regular expression guard of first session.reader (to make sure we are at the prompt we want)
  # @param command String, representing the command we want to issue
  # @param output Boolean, boolean flag (true/false) representing if or if not output is desired (used by the wrapper functions, send and receive)
  # @param session OStruct containing the PTY objects @session.reader, @session.writer, @session.pid
  # @returns If output false, returns nothing, if true returns output from second session.reader attempt
  def execute if_pattern, command, output, session = @session # {{{
    message :debug, "Execute | Pattern (#{if_pattern.to_s}), Command (#{command.to_s})"
    session.reader.expect( if_pattern ) do |o|
      unless( command.nil? )
        session.writer.puts( command )
      else
        output = o
      end
    end # of @session.reader.expect

    unless( command.nil? )
      if( output )
        session.reader.expect( if_pattern ) do |o|
          output = o
        end
      end
    end

    output.to_s.split( "\n" ).collect { |i| i.strip }
  end # of def execute }}}

end # of class OfflineIMAPFolderManager }}}



# = Direct invocation
if __FILE__ == $0 # {{{

  options = OfflineIMAPFolderManager.new.parse_cmd_arguments( ARGV )
  o       = OfflineIMAPFolderManager.new( options )

end # of if __FILE__ == $0 }}}

