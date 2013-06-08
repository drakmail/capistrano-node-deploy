require "digest/md5"
require "railsless-deploy"
require "multi_json"

def remote_file_exists?(full_path)
  'true' ==  capture("if [ -e #{full_path} ]; then echo 'true'; fi").strip
end

def remote_file_content_same_as?(full_path, content)
  Digest::MD5.hexdigest(content) == capture("md5sum #{full_path} | awk '{ print $1 }'").strip
end

def remote_file_differs?(full_path, content)
  exists = remote_file_exists?(full_path)
  !exists || exists && !remote_file_content_same_as?(full_path, content)
end

Capistrano::Configuration.instance(:must_exist).load do |configuration|
  before "deploy", "deploy:create_release_dir"
  before "deploy", "node:check_init_config"
  after "deploy:update", "node:install_packages", "node:restart"
  after "deploy:rollback", "node:restart"

  package_json = MultiJson.load(File.open("package.json").read) rescue {}

  set :application, package_json["name"] unless defined? application
  set :app_command, package_json["main"] || "index.js" unless defined? app_command
  set :app_environment, "" unless defined? app_environment

  set :node_binary, "/usr/bin/node" unless defined? node_binary
  set :node_env, "production" unless defined? node_env
  set :node_user, "deploy" unless defined? node_user

  set :init_job_name, lambda { "#{application}-#{node_env}" } unless defined? init_job_name
  set :init_file_path, lambda { "/etc/init.d/#{init_job_name}" } unless defined? init_file_path
  _cset(:init_file_contents) {
<<EOD
#! /bin/sh
### BEGIN INIT INFO
# Provides:          #{application}-#{node_env}
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start #{application} with node.js
### END INIT INFO

# Author: Alexander Maslov <drakmail@delta.pm>

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
DESC="It run #{application}"
NAME=node
DAEMON=/usr/local/bin/$NAME
DAEMON_ARGS="#{current_path}/#{app_command}"
PIDFILE=/var/run/$NAME.pid
SCRIPTNAME=/etc/init.d/#{init_job_name}
[ -x "$DAEMON" ] || exit 0
[ -r /etc/default/$NAME ] && . /etc/default/$NAME
. /lib/init/vars.sh
. /lib/lsb/init-functions

do_start()
{
	start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON --test > /dev/null \
		|| return 1
	start-stop-daemon --start --quiet --pidfile $PIDFILE -b -m --exec $DAEMON -- \
		$DAEMON_ARGS 2> /var/log/$NAME.log \
		|| return 2
}

do_stop()
{
	start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --pidfile $PIDFILE --name $NAME
	RETVAL="$?"
	[ "$RETVAL" = 2 ] && return 2
	start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec $DAEMON
	[ "$?" = 2 ] && return 2
	rm -f $PIDFILE
	return "$RETVAL"
}

do_reload() {
	start-stop-daemon --stop --signal 1 --quiet --pidfile $PIDFILE --name $NAME
	return 0
}

case "$1" in
  start)
	[ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
	do_start
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  stop)
	[ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
	do_stop
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  status)
	status_of_proc "$DAEMON" "$NAME" && exit 0 || exit $?
	;;
  restart|force-reload)
	log_daemon_msg "Restarting $DESC" "$NAME"
	do_stop
	case "$?" in
	  0|1)
		do_start
		case "$?" in
			0) log_end_msg 0 ;;
			1) log_end_msg 1 ;; # Old process is still running
			*) log_end_msg 1 ;; # Failed to start
		esac
		;;
	  *)
		log_end_msg 1
		;;
	esac
	;;
  *)
	echo "Usage: $SCRIPTNAME {start|stop|status|restart|force-reload}" >&2
	exit 3
	;;
esac
:
EOD
  }


  namespace :node do
    desc "Check required packages and install if packages are not installed"
    task :install_packages do
      run "cp #{release_path}/package.json #{shared_path}"
      run "cd #{shared_path} && npm install #{(node_env != 'production') ? '--dev' : ''}"
      run "ln -s #{shared_path}/node_modules #{release_path}/node_modules"
    end

    task :check_init_config do
      create_init_config if remote_file_differs?(init_file_path, init_file_contents)
    end

    desc "Create init script for this node app"
    task :create_init_config do
      temp_config_file_path = "#{shared_path}/#{application}.conf"

      # Generate and upload the init script
      put init_file_contents, temp_config_file_path

      # Copy the script into place and make executable
      sudo "cp #{temp_config_file_path} #{init_file_path}"
      sudo "chmod +x #{init_file_path}"
    end

    desc "Start the node application"
    task :start do
      sudo "/etc/init.d/#{init_job_name} start"
    end

    desc "Stop the node application"
    task :stop do
      sudo "/etc/init.d/#{init_job_name} stop"
    end

    desc "Restart the node application"
    task :restart do
      sudo "/etc/init.d/#{init_job_name} restart"
    end
  end

  namespace :deploy do
    task :create_release_dir, :except => {:no_release => true} do
      mkdir_releases = "mkdir -p #{fetch :releases_path}"
      mkdir_commands = ["log", "pids"].map {|dir| "mkdir -p #{shared_path}/#{dir}"}
      run mkdir_commands.unshift(mkdir_releases).join(" && ")
    end
  end
end
