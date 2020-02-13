package Mail::Milter::Authentication;
use 5.20.0;
use strict;
use warnings;
use Mail::Milter::Authentication::Pragmas;
# ABSTRACT: A Perl Mail Authentication Milter
# VERSION
use base 'Net::Server::PreFork';
use Mail::Milter::Authentication::Handler;
use Mail::Milter::Authentication::Metric;
use Mail::Milter::Authentication::Protocol::Milter;
use Mail::Milter::Authentication::Protocol::SMTP;
use ExtUtils::Installed;
use Log::Dispatchouli;
use Net::DNS::Resolver;
use Net::IP;
use Proc::ProcessTable;
use vars qw(@ISA);

=head1 DESCRIPTION

A Perl Implementation of email authentication standards rolled up into a single easy to use milter.

=head1 SYNOPSIS

Subclass of Net::Server::PreFork for bringing up the main server process for authentication_milter.

This class handles the server aspects of Authentication Milter.

For individual Protocol handling please see the Mail::Milter::Authentication::Protocol::* classes

For request handling please see Mail::Milter::Authentication::Handler

Please see Net::Server docs for more detail of the server code.

Please see the output of 'authentication_milter --help' for usage help.

=cut

{
    my $LOGGER;
    sub logger {

        return $LOGGER if $LOGGER;
        my $config = get_config();

        my $MYARGS = {
            'ident' => $Mail::Milter::Authentication::Config::IDENT,
            'to_stderr' => 0, # handled elsewhere
            'log_pid' => 1,
            'facility' => LOG_MAIL,
        };
        if ( exists $config->{ 'log_dispatchouli' } ) {
            $MYARGS = $config->{ 'log_dispatchouli' };
        }

        $LOGGER = Log::Dispatchouli->new( $MYARGS );
        $LOGGER->log('Logging instantiated');
        return $LOGGER;
    }
}

sub _warn($msg) {
    my @parts = split "\n", $msg;
    foreach my $part ( @parts ) {
        next if $part eq q{};
        print STDERR scalar(localtime) . ' ' . $Mail::Milter::Authentication::Config::IDENT . "[$PID] $part\n";
    }
}

=method preload_modules( $from, $matching )

Preload (pre-fork) lazy loading modules.

Takes a Package Name and a Base module, and loads all modules which match.

=cut

sub preload_modules($self,$from,$matching) {
    my $installed = ExtUtils::Installed->new( 'skip_cwd' => 1 );
    my $path_matching = $matching;
    $path_matching =~ s/::/\//g;
    foreach my $module ( grep { /$from/ } $installed->modules() ) {
        FILE:
        foreach my $file ( grep { /$path_matching\/\w+\.pm$/ } $installed->files( $module ) ) {
            next FILE if ! -e $file;
            my ( $module ) = reverse split '/', $file;
            $module =~ s/\.pm$//;
            $module = join( '::', $matching, $module );
            if ( ! is_loaded( $module ) ) {
                $self->logdebug( "Preloading Module $module" );
                load $module;
            }
            else {
                $self->logdebug( "Preloading Module $module already loaded" );
            }
        }
    }
}

=func I<get_installed_handlers()>

Return an array ref of installed handler modules.

=cut

sub get_installed_handlers {
    my @installed_handlers;
    my $installed = ExtUtils::Installed->new( 'skip_cwd' => 1 );
    foreach my $module ( grep { /Mail::Milter::Authentication/ } $installed->modules() ) {
        FILE:
        foreach my $file ( grep { /Mail\/Milter\/Authentication\/Handler\/\w+\.pm$/ } $installed->files( $module ) ) {
            next FILE if ! -e $file;
            my ( $handler ) = reverse split '/', $file;
            $handler =~ s/\.pm$//;
            push @installed_handlers, $handler;
        }
    }
    return \@installed_handlers;
}

=method I<write_to_log_hook()>

Hook which runs to write logs

=cut

sub write_to_log_hook($self,$priority,$line,@) {
    my $log_priority = $priority == 0 ? 'debug'
                     : $priority == 1 ? 'info'
                     : $priority == 2 ? 'notice'
                     : $priority == 3 ? 'warning'
                     : $priority == 4 ? 'error'
                     : 'debug';
    logger()->log( { 'level' => $log_priority }, $line );
}

=method I<idle_loop_hook()>

Hook which runs in the master periodically.

=cut

sub idle_loop_hook($self,@) {
    $self->{'metric'}->master_metric_update( $self );
}

=method I<pre_loop_hook()>

Hook which runs in the master before looping.

=cut

sub pre_loop_hook($self,@) {
    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':master';

    $self->preload_modules( 'Net::DNS', 'Net::DNS::RR' );
    $self->{'metric'} = Mail::Milter::Authentication::Metric->new();

    # Load handlers
    my $config = get_config();
    foreach my $name ( @{$config->{'load_handlers'}} ) {
        $self->load_handler( $name );

        my $package = "Mail::Milter::Authentication::Handler::$name";
        my $object = $package->new( $self );
        if ( $object->can( 'pre_loop_setup' ) ) {
            $object->pre_loop_setup();
        }
        if ( $object->can( 'register_metrics' ) ) {
            $self->{'metric'}->register_metrics( $object->register_metrics() );
        }

    }

    $self->{'metric'}->register_metrics( {
        'forked_children_total' => 'Total number of child processes forked',
        'reaped_children_total' => 'Total number of child processes reaped',
    } );

    $self->{'metric'}->register_metrics( Mail::Milter::Authentication::Handler->register_metrics() );

    if ( $config->{'protocol'} eq 'milter' ) {
        $self->{'metric'}->register_metrics( Mail::Milter::Authentication::Protocol::Milter->register_metrics() );
    }
    elsif ( $config->{'protocol'} eq 'smtp' ) {
        $self->{'metric'}->register_metrics( Mail::Milter::Authentication::Protocol::SMTP->register_metrics() );
    }
    else {
        die "Unknown protocol " . $config->{'protocol'} . "\n";
    }

    if ( $config->{'error_log'} ) {
        open( STDERR, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
        open( STDOUT, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
    }
}

=method I<run_n_children_hook()>

Hook which runs in parent before it forks children.

=cut

sub run_n_children_hook($self,@) {
    # Load handlers
    my $config = get_config();
    foreach my $name ( @{$config->{'load_handlers'}} ) {

        my $package = "Mail::Milter::Authentication::Handler::$name";
        my $object = $package->new( $self );
        if ( $object->can( 'pre_fork_setup' ) ) {
            $object->pre_fork_setup();
        }

    }
}

=method I<child_init_hook()>

Hook which runs after forking, sets up per process items.

=cut

sub child_init_hook($self,@) {
    srand();

    my $config = get_config();
    $self->{'config'} = $config;

    if ( $config->{'error_log'} ) {
        eval {
            open( STDERR, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
            open( STDOUT, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
        };
        if ( my $error = $@ ) {
            $self->logerror( "Child process $PID could not open the error log: $error" );
        }
    }

    $self->loginfo( "Child process $PID starting up" );
    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':starting';

    my $base;
    if ( $config->{'protocol'} eq 'milter' ) {
        $base = 'Mail::Milter::Authentication::Protocol::Milter';
    }
    elsif ( $config->{'protocol'} eq 'smtp' ) {
        $base = 'Mail::Milter::Authentication::Protocol::SMTP';
    }
    else {
        die "Unknown protocol " . $config->{'protocol'} . "\n";
    }
    push @ISA, $base;

    # BEGIN MILTER PROTOCOL BLOCK
    if ( $config->{'protocol'} eq 'milter' ) {
        my $protocol  = SMFIP_NONE & ~(SMFIP_NOCONNECT|SMFIP_NOMAIL);
           $protocol &= ~SMFIP_NOHELO;
           $protocol &= ~SMFIP_NORCPT;
           $protocol &= ~SMFIP_NOBODY;
           $protocol &= ~SMFIP_NOHDRS;
           $protocol &= ~SMFIP_NOEOH;
        $self->{'protocol'} = $protocol;

        my $callback_flags = SMFI_CURR_ACTS|SMFIF_CHGBODY|SMFIF_QUARANTINE|SMFIF_SETSENDER;
        $self->{'callback_flags'} = $callback_flags;
    }
    # END MILTER PROTOCOL BLOCK

    my $callbacks_list = {};
    my $callbacks      = {};
    my $handler        = {};
    my $object         = {};
    my $object_maker   = {};
    my $count          = 0;

    $self->{'callbacks_list'} = $callbacks_list;
    $self->{'callbacks'}      = $callbacks;
    $self->{'count'}          = $count;
    $self->{'handler'}        = $handler;
    $self->{'object'}         = $object;
    $self->{'object_maker'}   = $object_maker;

    $self->setup_handlers();
    $self->{'metric'}->set_versions( $self );

    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':waiting(0)';
}

=method I<child_finish_hook()>

Hook which runs when the child is about to finish.

=cut

sub child_finish_hook($self,@) {
    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':exiting';
    $self->loginfo( "Child process $PID shutting down" );
    eval {
        $self->{'handler'}->{'_Handler'}->metric_count( 'reaped_children_total', {}, 1 );
    };
    $self->destroy_objects();
}

=method I<pre_server_close_hook()>

Hook which runs before the server closes.

=cut

sub pre_server_close_hook($self,@) {
    $self->loginfo( 'Server closing down' );
}

=method I<get_client_proto()>

Get the protocol of the connecting client.

=cut

sub get_client_proto($self,@) {
    my $socket = $self->{server}{client};
    if ($socket->isa("Net::Server::Proto")) {
        my $proto = $socket->NS_proto;
        $proto = "UNIX" if $proto =~ m/^UNIX/;
        return $proto;
    }

    if ($socket->isa("IO::Socket::INET")) {
        return "TCP";
    }

    if ($socket->isa("IO::Socket::INET6")) {
      return "TCP";
    }

    if ($socket->isa("IO::Socket::UNIX")) {
        return "UNIX";
    }

    $self->logerror( "Could not determine connection protocol: " . ref($socket) );
}

=method I<get_client_port()>

Get the port of the connecting client.

=cut

sub get_client_port($self,@) {
    my $socket = $self->{server}{client};
    return $socket->sockport();
}

=method I<get_client_host()>

Get the host of the connecting client.

=cut

sub get_client_host($self,@) {
    my $socket = $self->{server}{client};
    return $socket->sockhost();
}

=method I<get_client_path()>

Get the path of the connecting client.

=cut

sub get_client_path($self,@) {
    my $socket = $self->{server}{client};
    return $socket->hostpath();
}

=method I<get_client_details()>

Get the details of the connecting client.

=cut

sub get_client_details($self,@) {
    my $proto = lc $self->get_client_proto();
    if ( $proto eq 'tcp' ) {
        return 'inet:' . $self->get_client_port();
    }
    elsif ( $proto eq 'unix' ) {
        return 'unix:' . $self->get_client_path();
    }
}

=method I<process_request()>

Hook which runs for each request, passes control to metrics handler or process_main as appropriate.

=cut

sub process_request($self,@) {
    my $config = $self->{'config'};

    my $metric_type;
    my $metric_path;
    my $metric_host;

    if ( defined( $config->{'metric_connection'} ) ) {
        my $connection = $config->{'metric_connection'};
        my $umask      = $config->{'metric_umask'};

        $connection =~ /^([^:]+):([^:@]+)(?:@([^:@]+|\[[0-9a-f:\.]+\]))?$/;
        $metric_type = $1;
        $metric_path = $2;
        $metric_host = $3 || q{};
    }

    ## ToDo, match also on client_host

    # Legacy metrics
    if ( defined( $config->{ 'metric_port' } ) && $self->get_client_proto() eq 'TCP' && $self->get_client_port() eq $config->{'metric_port'} ) {
        $self->{'metric'}->child_handler( $self );
    }

    elsif ( defined( $config->{ 'metric_connection' } ) && $metric_type eq 'inet' && $self->get_client_proto eq 'TCP' && $self->get_client_port() eq $metric_path ) {
        $self->{'metric'}->child_handler( $self );
    }

    elsif ( defined( $config->{ 'metric_connection' } ) && $metric_type eq 'unix' && $self->get_client_proto eq 'UNIX' && $self->get_client_path() eq $metric_path ) {
        $self->{'metric'}->child_handler( $self );
    }

    else {
        $self->process_main();
    }

    my $count = $self->{'count'};
    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':waiting(' . $count . ')';
}

=method I<process_main()>

Method which runs for each request, sets up per request items and processes the request.

=cut

sub process_main($self,@) {
    $self->{'count'}++;
    my $count = $self->{'count'};
    my $config = $self->{'config'};

    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':processing(' . $count . ')';
    $self->logdebug( 'Processing request ' . $self->{'count'} );
    $self->{'socket'} = $self->{'server'}->{'client'};

    $self->protocol_process_request();

    # Call close callback
    $self->{'handler'}->{'_Handler'}->top_close_callback();
    if ( $self->{'handler'}->{'_Handler'}->{'exit_on_close'} ) {
        my $error = $self->{'handler'}->{'_Handler'}->{'exit_on_close_error'} // 'no reason given';

        {
            my $email = "Authentication Milter " . $Mail::Milter::Authentication::Config::IDENT , " Fatal Error\n\n";
            $email .= "$error\n\n"

            $email .= "Child PID: $PID\n\n";

            $email .= "Processes: "
                   . "processing=".$self->$server->{'server'}->{'tally'}->{processing}." "
                   . "waiting=".$self->$server->{'server'}->{'tally'}->{waiting}."\n\n";

            $email .= "Processes Running\n";
            my $ppid = $self->{'server'}->{'ppid'};
            my $process_table = Proc::ProcessTable->new;
            my @fields = $process_table->fields;
            foreach my $process ( $process_table->table->@* ) {
                next if ! ( $process->pid == $ppid || $process->ppid == $ppid );
                my $uid = $process->uid;
                my $pid = $process->pid;
                my $cmndline = $process->cmndline;
                my $size   = $process->size;
                my $rss    = $process->rss;
                my $pctmem = $process->pctmem;
                my $pctcpu = $process->pctcpu;
                $email .= "pid:$pid, $cmndline, size:$size, mem:$rss ($pctmem%), cpu: $pctcpu%\n";
            }
        }


        $self->fatal('exit_on_close requested - '.$error);
    }

    if ( $config->{'debug'} ) {
        my $process_table = Proc::ProcessTable->new();
        foreach my $process ( @{$process_table->table} ) {
            if ( $process->pid == $PID ) {
                my $size   = $process->size;
                my $rss    = $process->rss;
                my $pctmem = $process->pctmem;
                my $pctcpu = $process->pctcpu;
                $self->loginfo( "Resource usage: ($count) size $size/rss $rss/memory $pctmem\%/cpu $pctcpu\%" );
            }
        }
    }

    delete $self->{'handler'}->{'_Handler'}->{'reject_mail'};
    delete $self->{'handler'}->{'_Handler'}->{'return_code'};
    delete $self->{'socket'};
    $self->logdebug( 'Request processing completed' );
}



=func I<get_valid_pid($pid_file)>

Given a pid file, check for a valid process ID and return if valid.

=cut

sub get_valid_pid($pid_file) {
    if ( ! $pid_file ) {
        return undef; ## no critic
    }
    if ( ! -e $pid_file ) {
        return undef; ## no critic
    }

    open my $inf, '<', $pid_file || return undef; ## no critic
    my $pid = <$inf>;
    close $inf;

    my $self_pid   = $PID;
    my $found_self = 0;
    my $found_pid  = 0;

    my $process_table = Proc::ProcessTable->new();
    foreach my $process ( $process_table->table->@* ) {
        if ( $process->pid == $self_pid ) {
            if ( $process->cmndline eq $Mail::Milter::Authentication::Config::IDENT . ':control' ) {
                $found_self = 1;
            }
        }
        if ( $process->pid == $pid ) {
            $found_pid = 1;
            if ( $process->cmndline eq $Mail::Milter::Authentication::Config::IDENT . ':master' ) {
                return $pid;
            }
        }
    }

    # If we didn't find ourself in the process table then we can assume that
    # $0 is read only on our current operating system, and return the pid that we read from the
    # pidfile if it is in the process table regardness of it's process name..
    if ( ! $found_self ) {
        if ( $found_pid ) {
            return $pid;
        }
    }

    return undef; ## no critic
}

=func I<find_process()>

Search the process table for an authentication_milter master process

=cut

sub find_process {
    my $process_table = Proc::ProcessTable->new();
    foreach my $process ( $process_table->table->@* ) {
        if ( $process->cmndline eq $Mail::Milter::Authentication::Config::IDENT . ':master' ) {
            return $process->pid;
        }
    }
    return undef; ## no critic
}

=func I<control($command)>

Run a daemon command.  Command can be one of start/restart/stop/status.

=cut

sub control($args) {
    my $pid_file = $args->{'pid_file'};
    my $command  = $args->{'command'};

    my $OriginalProgramName = $PROGRAM_NAME;
    $PROGRAM_NAME = $Mail::Milter::Authentication::Config::IDENT . ':control';

    if ( $command eq 'stop' ) {
        my $pid = get_valid_pid( $pid_file ) || find_process();
        if ( $pid ) {
            print "Process found, stopping\n";
            kill 'QUIT', $pid;
        }
        else {
            print "No process found\n";
        }
    }
    elsif ( $command eq 'restart' || $command eq 'start' ) {
        my $pid = get_valid_pid( $pid_file ) || find_process();
        if ( $pid ) {
            print "Process found, restarting\n";
            kill 'HUP', $pid;
        }
        else {
            print "No process found, starting up\n";
            $PROGRAM_NAME = $OriginalProgramName;
            start({
                'pid_file'   => $pid_file,
                'daemon'     => 1,
            });
        }
    }
    elsif ( $command eq 'status' ) {
        my $pid = get_valid_pid( $pid_file ) || find_process();
        if ( $pid ) {
            print "Process running with pid $pid\n";
            if ( ! get_valid_pid( $pid_file ) ) {
                print "pid file $pid_file is invalid\n";
            }
        }
        else {
            print "No process found\n";
        }
    }
    else {
        die 'unknown command';
    }
}

=func I<start($hashref)>

Start the server. This method does not return.

    $hashref = {
        'pid_file'   => 'The pid file to use', #
        'daemon'     => 1/0,                   # Daemonize process?
    }

=cut

sub start($args) {
    local $SIG{__WARN__} = sub {
        foreach my $msg ( @_ ) {
            logger()->log( { level => 'warning' }, "Warning: $msg" );
            _warn( "Warning: $msg" );
        }
    };

    my $config                 = get_config();

    my $default_connection     = $config->{'connection'}             || die('No connection details given');

    my $pid_file               = $args->{'pid_file'};

    my $listen_backlog         = $config->{'listen_backlog'}         || 20;
    my $max_children           = $config->{'max_children'}           || 100;
    my $max_requests_per_child = $config->{'max_requests_per_child'} || 200;
    my $min_children           = $config->{'min_children'}           || 20;
    my $max_spare_children     = $config->{'max_spare_children'}     || 20;
    my $min_spare_children     = $config->{'min_spare_children'}     || 10;

    my %srvargs;

    $srvargs{'no_client_stdout'} = 1;

    # Early redirection to log file if possible
    if ( $config->{'error_log'} ) {
        open( STDERR, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
        open( STDOUT, '>>', $config->{'error_log'} ) || die "Cannot open errlog [$!]";
    }

    if ( $args->{'daemon'} ) {
        if ( $EUID == 0 ) {
            _warn(
                join( ' ',
                    'daemonize',
                    "servers=$min_children/$max_children",
                    "spares=$min_spare_children/$max_spare_children",
                    "requests=$max_requests_per_child",
                )
            );
            $srvargs{'background'}        = 1;
            $srvargs{'setsid'}            = 1;
        }
        else {
            _warn("Not running as root, daemonize ignored!");
        }
    }
    $srvargs{'pid_file'}          = $pid_file;
    $srvargs{'max_servers'}       = $max_children;
    $srvargs{'max_requests'}      = $max_requests_per_child;
    $srvargs{'min_servers'}       = $min_children;
    $srvargs{'min_spare_servers'} = $min_spare_children;
    $srvargs{'max_spare_servers'} = $max_spare_children;

    if ( $EUID == 0 ) {
        my $user  = $config->{'runas'};
        my $group = $config->{'rungroup'};
        if ( $user && $group ) {
        _warn("run as user=$user group=$group");
            $srvargs{'user'}  = $user;
            $srvargs{'group'} = $group;
        }
        else {
            _warn("No runas details supplied, could not drop privs - be careful!");
        }
        # Note, Chroot requires a chroot environment which is out of scope at present
        if ( $config->{'error_log'} ) {
            if ( ! -e $config->{'error_log'} ) {
                open my $outf, '>', $config->{'error_log'} || die "Could not create error log: $!\n";;
                close $outf;
            }
            if ( $user ) {
                my ($login,$pass,$uid,$gid) = getpwnam($user);
                chown $uid, $gid, $config->{'error_log'};
            }
        }
        if ( exists( $config->{'chroot'} ) ) {
            _warn('Chroot to ' . $config->{'chroot'});
            $srvargs{'chroot'} = $config->{'chroot'};
        }
    }
    else {
        _warn("Not running as root, could not drop privs - be careful!");
    }

    my $connections = {};

    if ( exists $config->{'connections'} ) {
        $connections = $config->{'connections'};
    }

    $connections->{'default'} = {
        'connection' => $default_connection,
        'umask'      => $config->{'umask'},
    };

    my @ports;
    foreach my $key ( keys %$connections ) {
        my $connection = $connections->{$key}->{'connection'};
        my $umask      = $connections->{$key}->{'umask'};

        $connection =~ /^([^:]+):([^:@]+)(?:@([^:@]+|\[[0-9a-f:\.]+\]))?$/;
        my $type = $1;
        my $path = $2;
        my $host = $3 || q{};
        if ( $type eq 'inet' ) {
            _warn(
                join( ' ',
                    'listening on inet',
                    "host=$host",
                    "port=$path",
                    "backlog=$listen_backlog",
                )
            );
            push @ports, {
                'host'  => $host,
                'port'  => $path,
                'ipv'   => '*',
                'proto' => 'tcp',
            };
        }
        elsif ( $type eq 'unix' ) {
            _warn(
                join( ' ',
                    'listening on unix',
                    "socket=$path",
                    "backlog=$listen_backlog",
                )
            );
            push @ports, {
                'port'  => $path,
                'proto' => 'unix',
            };

            if ($umask) {
                umask ( oct( $umask ) );
                _warn( 'setting umask to ' . $umask );
            }

        }
        else {
            die 'Invalid connection';
        }
    }

    if ( defined( $config->{'metric_connection'} ) ) {
        my $connection = $config->{'metric_connection'};
        my $umask      = $config->{'metric_umask'};

        $connection =~ /^([^:]+):([^:@]+)(?:@([^:@]+|\[[0-9a-f:\.]+\]))?$/;
        my $type = $1;
        my $path = $2;
        my $host = $3 || q{};
        if ( $type eq 'inet' ) {
            _warn(
                join( ' ',
                    'metrics listening on inet',
                    "host=$host",
                    "port=$path",
                    "backlog=$listen_backlog",
                )
            );
            push @ports, {
                'host'  => $host,
                'port'  => $path,
                'ipv'   => '*',
                'proto' => 'tcp',
            };
            $srvargs{'child_communication'} = 1;
        }
        elsif ( $type eq 'unix' ) {
            _warn(
                join( ' ',
                    'metrics listening on unix',
                    "socket=$path",
                    "backlog=$listen_backlog",
                )
            );
            push @ports, {
                'port'  => $path,
                'proto' => 'unix',
            };
            $srvargs{'child_communication'} = 0;

            if ($umask) {
                umask ( oct( $umask ) );
                _warn( 'setting umask to ' . $umask );
            }

        }
        else {
            die 'Invalid metrics connection';
        }

        if ( defined( $config->{'metric_port'} ) ) {
            _warn( 'metric_port ignored when metric_connection supplied' );
        }

    }
    elsif ( defined( $config->{'metric_port'} ) ) {
        my $metric_host = $config->{ 'metric_host' } || '127.0.0.1';
        push @ports, {
            'host'  => $metric_host,
            'port'  => $config->{'metric_port'},
            'ipv'   => '*',
            'proto' => 'tcp',
        };
        $srvargs{'child_communication'} = 1;
        _warn( 'Metrics available on ' . $metric_host . ':' . $config->{'metric_port'} );
        _warn( 'metric_host/metric_port are depricated, please use metric_connection/metric_umask instead' );
    }

    $srvargs{'port'} = \@ports;
    $srvargs{'listen'} = $listen_backlog;
    $srvargs{'leave_children_open_on_hup'} = 1;

    _warn "==========";
    _warn "Starting server";
    _warn "Running with perl $PERL_VERSION";
    _warn "==========";

    my @start_times;
    my $parent_pid = $PID;
    while ( 1 ) {
        unshift @start_times, time();

        eval {
            __PACKAGE__->run( %srvargs );
        };
        my $error = $@;
        if ( $PID != $parent_pid ) {
            _warn "Child exiting";
            die;
        }
        $error = 'unknown error' if ! $error;
        _warn "Server failed: $error";

        if ( scalar @start_times >= 4 ) {
            if ( $start_times[3] > ( time() - 120 ) ) {
                _warn "Abandoning automatic restart: too many restarts in a short time";
                last;
            }
        }

        _warn "Attempting automatic restart";
        sleep 10;
    }
    _warn "Server exiting abnormally";
    die;
}

##### Protocol methods

=method I<fatal($error)>

Log a fatal error and die in child

=cut

sub fatal($self,$error) {
    $self->logerror( "Child process $PID shutting down due to fatal error: $error" );
    die "$error\n";
}

=method I<fatal_global($error)>

Log a fatal error and die in child and parent

=cut

sub fatal_global($self,$error) {
    my $ppid = $self->{'server'}->{'ppid'};
    if ( $ppid == $PID ) {
        $self->logerror( "Global shut down due to fatal error: $error" );
    }
    else {
        $self->logerror( "Child process $PID signalling global shut down due to fatal error: $error" );
        kill 'Term', $ppid;
    }
    die "$error\n";
}

=method I<setup_handlers()>

Setup the Handler objects.

=cut

sub setup_handlers($self) {
    $self->logdebug( 'setup objects' );
    my $handler = Mail::Milter::Authentication::Handler->new( $self );
    $self->{'handler'}->{'_Handler'} = $handler;

    $handler->metric_count( 'forked_children_total', {}, 1 );

    my $config = $self->{'config'};
    foreach my $name ( $config->{'load_handlers'}->@* ) {
        $self->setup_handler( $name );
    }
    $self->sort_all_callbacks();
}

=method I<load_handler( $name )>

Load the $name Handler module

=cut

sub load_handler($self,$name) {
    ## TODO error handling here
    $self->logdebug( "Load Handler $name" );

    my $package = "Mail::Milter::Authentication::Handler::$name";
    if ( ! is_loaded ( $package ) ) {
        $self->logdebug( "Load Handler Module $name" );
        eval { load $package; };
        if ( my $error = $@ ) {
            $self->fatal_global('Could not load handler ' . $name . ' : ' . $error);
        }
    }
}

=method I<setup_handler( $name )>

Setup the $name Handler object

=cut

sub setup_handler($self,$name) {
    ## TODO error handling here
    $self->logdebug( "Instantiate Handler $name" );

    my $package = "Mail::Milter::Authentication::Handler::$name";
    my $object = $package->new( $self );
    $self->{'handler'}->{$name} = $object;

    foreach my $callback ( qw { metrics setup connect helo envfrom envrcpt header eoh body eom addheader abort close } ) {
        if ( $object->can( $callback . '_callback' ) ) {
            $self->register_callback( $name, $callback );
        }
    }
}

=method I<destroy_handler( $name )>

Remove the $name Handler

=cut

sub destroy_handler {
    # Unused!
    my ( $self, $name ) = @_;
    # Remove some back references
    delete $self->{'handler'}->{$name}->{'thischild'};
    # Remove reference to handler
    delete $self->{'handler'}->{$name};
}

=method I<register_callback( $name, $callback )>

Register the specified callback

=cut

sub register_callback($self,$name,$callback) {
    $self->logdebug( "Register Callback $name:$callback" );
    if ( ! exists $self->{'callbacks'}->{$callback} ) {
        $self->{'callbacks'}->{$callback} = [];
    }
    push @{ $self->{'callbacks'}->{$callback} }, $name;
}

=method I<sort_all_callbacks()>

Sort the callbacks into the order in which they must be called

=cut

sub sort_all_callbacks($self) {
    foreach my $callback ( qw { metrics setup connect helo envfrom envrcpt header eoh body eom addheader abort close } ) {
        $self->sort_callbacks( $callback );
    }
}

=method I<sort_callbacks( $callback )>

Sort the callbacks for the $callback callback into the right order

=cut

sub sort_callbacks($self,$callback) {
    if ( ! exists $self->{'callbacks'}->{$callback} ) {
        $self->{'callbacks'}->{$callback} = [];
    }

    if ( ! exists $self->{'callbacks_list'}->{$callback} ) {
        $self->{'callbacks_list'}->{$callback} = [];
    }
    else {
        return $self->{'callbacks_list'}->{$callback};
    }

    my $callbacks_ref = $self->{'callbacks'}->{$callback};

    my $added = {};
    my @order;

    my @todo = sort @{$callbacks_ref};
    my $todo_count = scalar @todo;

    # Process requirements
    my $requirements = {};
    foreach my $item ( @todo ) {
        $requirements->{ $item } = [];
        my $handler = $self->{'handler'}->{ $item };
        my $requires_method = $callback . '_requires';
        if ( $handler->can( $requires_method ) ) {
            my $requires = $handler->$requires_method;
            foreach my $require ( $requires->@* ) {
                push @{ $requirements->{ $item } }, $require;
            }
        }
    }
    foreach my $item ( @todo ) {
        my $handler = $self->{'handler'}->{ $item };
        my $requires_method = $callback . '_required_before';
        if ( $handler->can( $requires_method ) ) {
            my $requires = $handler->$requires_method;
            foreach my $require ( $requires->@* ) {
                push @{ $requirements->{ $require } }, $item;
            }
        }
    }

    while ( $todo_count ) {
        my @defer;
        foreach my $item ( @todo ) {
            my $requires_met = 1;
            my $requires = $requirements->{ $item };
            foreach my $require ( $requires->@* ) {
                if ( ! exists $added->{$require} ) {
                    $requires_met = 0;
                }
            }
            if ( $requires_met == 1 ) {
                push @order, $item;
                $added->{$item} = 1;
            }
            else {
                push @defer, $item;
            }
        }

        my $defer_count = scalar @defer;
        if ( $defer_count == $todo_count ) {
            $self->fatal_global('Could not build order list');
        }
        $todo_count = $defer_count;
        @todo = @defer;
    }

    $self->{'callbacks_list'}->{$callback} = \@order;
}

=method I<destroy_objects()>

Remove references to all objects

=cut

sub destroy_objects($self) {
    $self->logdebug ( 'destroy objects' );
    my $handler = $self->{'handler'}->{'_Handler'};
    if ( $handler ) {
        $handler->destroy_all_objects();
        my $config = $self->{'config'};
        foreach my $name ( $config->{'load_handlers'}->@* )  {
            $self->destroy_handler( $name );
        }
        delete $self->{'handler'}->{'_Handler'}->{'config'};
        delete $self->{'handler'}->{'_Handler'}->{'thischild'};
        delete $self->{'handler'}->{'_Handler'};
    }
}




## Logging

=method I<get_queue_id()>

Return the queue ID (for logging) if possible.

=cut

sub get_queue_id($self) {
    my $queue_id;

    if ( exists ( $self->{'smtp'} ) ) {
        if ( $self->{'smtp'}->{'queue_id'} ) {
            $queue_id = $self->{'smtp'}->{'queue_id'};
        }
    }
    elsif ( exists ( $self->{'handler'}->{'_Handler'} ) ) {
        $queue_id = $self->{'handler'}->{'_Handler'}->get_symbol('i');
    }

    return $queue_id;
}

=method I<enable_extra_debugging()>

Turn on extra debugging mode, will cause child to exit on close.

=cut

sub enable_extra_debugging($self) {
    my $config = $self->{'config'} || get_config();
    $config->{'logtoerr'} = 1;
    $config->{'debug'}    = 1;
    $self->{'extra_debugging'} = 1;
    $self->logerror( 'Extra debugging enabled. Child will exit on close.' );
    # We don't want to persist this, so force an exit on close state.
    $self->{'handler'}->{'_Handler'}->{'exit_on_close'} = 1;
}

=method I<extra_debugging( $line )>

Cause $line to be written to log if extra debugging mode is enabled.

=cut

sub extra_debugging($self,$line) {
    if ( $self->{'extra_debugging'} ) {
        $self->logerror( $line );
    }
}

=method I<logerror( $line )>

Log to the error log.

=cut

sub logerror($self,$line) {
    my $config = $self->{'config'} || get_config();
    if ( my $queue_id = $self->get_queue_id() ) {
        $line = $queue_id . ': ' . $line;
    }
    _warn( $line ) if $config->{'logtoerr'};
    logger()->log( { 'level' => 'error' }, $line );
}

=method I<loginfo( $line )>

Log to the info log.

=cut

sub loginfo($self,$line) {
    my $config = $self->{'config'} || get_config();
    if ( my $queue_id = $self->get_queue_id() ) {
        $line = $queue_id . ': ' . $line;
    }
    _warn( $line ) if $config->{'logtoerr'};
    logger()->log( { 'level' => 'info' }, $line );
}

=method I<logdebug( $line )>

Log to the debug log.

=cut

sub logdebug($self,$line) {
    my $config = $self->{'config'} || get_config();
    if ( my $queue_id = $self->get_queue_id() ) {
        $line = $queue_id . ': ' . $line;
    }
    if ( $config->{'debug'} ) {
        _warn( $line ) if $config->{'logtoerr'};
        logger()->log( { 'level' => 'debug' }, $line );
    }
}

1;
