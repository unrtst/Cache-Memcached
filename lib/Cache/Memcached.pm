# $Id$
#
# Copyright (c) 2003, 2004  Brad Fitzpatrick <brad@danga.com>
#
# See COPYRIGHT section in pod text below for usage and distribution rights.
#

package Cache::Memcached;

use strict;
use warnings;

no strict 'refs';
use Storable ();
use Socket qw( MSG_NOSIGNAL PF_INET PF_UNIX IPPROTO_TCP SOCK_STREAM );
use IO::Handle ();
use Time::HiRes ();
use String::CRC32;
use Errno qw( EINPROGRESS EWOULDBLOCK EISCONN );
use Cache::Memcached::GetParser;
use Encode ();
use fields qw{
    debug no_rehash stats compress_threshold compress_enable stat_callback
    readonly select_timeout namespace namespace_len servers active buckets
    pref_ip
    bucketcount _single_sock _stime
    connect_timeout cb_connect_fail
    parser_class
    buck2sock buck2sock_generation
    compress_ratio     max_size
    compress_methods   serialize_methods
    enable_key_hashing key_hash_method
};

# flag definitions
use constant F_STORABLE => 1;
use constant F_COMPRESS => 2;

# size reduction required before saving compressed value
use constant DEFAULT_COMPRESS_RATIO => 0.80; # percent
# default max size of item values to store in memcached
# NOTE: Cache::Memcached::Fast uses a default of 1024*1024 (1mb).
#       Cache::Memcached disables this by default for backward compatibilty.
use constant DEFAULT_MAX_SIZE => 0; # bytes

use vars qw($VERSION $HAVE_ZLIB $FLAG_NOSIGNAL $HAVE_SOCKET6);
$VERSION = "1.33";

BEGIN {
    $HAVE_ZLIB = eval "use Compress::Zlib (); 1;";
    $HAVE_SOCKET6 = eval "use Socket6 qw(AF_INET6 PF_INET6); 1;";
}

my $HAVE_XS = eval "use Cache::Memcached::GetParserXS; 1;";
$HAVE_XS = 0 if $ENV{NO_XS};

my $parser_class = $HAVE_XS ? "Cache::Memcached::GetParserXS" : "Cache::Memcached::GetParser";
if ($ENV{XS_DEBUG}) {
    print "using parser: $parser_class\n";
}

$FLAG_NOSIGNAL = 0;
eval { $FLAG_NOSIGNAL = MSG_NOSIGNAL; };

my %host_dead;   # host -> unixtime marked dead until
my %cache_sock;  # host -> socket
my $socket_cache_generation = 1; # Set to 1 here because below the buck2sock_generation is set to 0, keep them in order.

my $PROTO_TCP;

our $SOCK_TIMEOUT = 2.6; # default timeout in seconds

sub new {
    my Cache::Memcached $self = shift;
    $self = fields::new( $self ) unless ref $self;

    my $args = (@_ == 1) ? shift : { @_ };  # hashref-ify args

    $self->{'buck2sock'}= [];
    $self->{'buck2sock_generation'} = 0;
    $self->set_servers($args->{'servers'});
    $self->{'debug'} = $args->{'debug'} || 0;
    $self->{'no_rehash'} = $args->{'no_rehash'};
    $self->{'stats'} = {};
    $self->{'pref_ip'} = $args->{'pref_ip'} || {};
    $self->{'compress_threshold'} = $args->{'compress_threshold'};
    $self->{'compress_ratio'}     = $args->{'compress_ratio'} || DEFAULT_COMPRESS_RATIO;
    $self->{'compress_enable'}    = (exists $args->{'compress_enable'} && length $args->{'compress_enable'})
                                  ? $args->{'compress_enable'}
                                  : 1;
    $self->{'stat_callback'} = $args->{'stat_callback'} || undef;
    $self->{'readonly'} = $args->{'readonly'};
    $self->{'parser_class'} = $args->{'parser_class'} || $parser_class;
    $self->{'max_size'}     = $args->{'max_size'} || DEFAULT_MAX_SIZE;

    if (ref( $args->{'compress_methods'} ) eq 'ARRAY') {
        $self->{'compress_methods'} = $args->{'compress_methods'};
    } elsif ($HAVE_ZLIB) {
        $self->{'compress_methods'} = [
            sub { ${$_[1]} = Compress::Zlib::memGzip(${$_[0]})   },
            sub { ${$_[1]} = Compress::Zlib::memGunzip(${$_[0]}) },
        ];
    } else {
        $self->{'compress_methods'} = undef;
    }

    if (ref( $args->{'serialize_methods'} ) eq 'ARRAY') {
        $self->{'serialize_methods'} = $args->{'serialize_methods'};
    } else {
        $self->{'serialize_methods'} = [ \&Storable::nfreeze, \&Storable::thaw ];
    }

    # implicitly enabled (but user can override via enable_key_hashing)
    if (exists $args->{'key_hash_method'} && ref $args->{'key_hash_method'}) {
        $self->{'enable_key_hashing'} = defined $args->{'enable_key_hashing'}
                                      ? $args->{'enable_key_hashing'}
                                      : 1;
        $self->{'key_hash_method'} = $args->{'key_hash_method'};
    }
    # enable built in key hashing
    elsif ($args->{'enable_key_hashing'}) {
        eval { require Digest::MD5 };
        if ($@) {
            print STDERR "Cache::Memcached: enable_key_hashing requested, but unable to load Digest::MD5: $@\n" if $self->{'debug'};
            $self->{'enable_key_hashing'} = 0;
            $self->{'key_hash_method'} = undef;
        } else {
            $self->{'enable_key_hashing'} = 1;
            $self->{'key_hash_method'} = sub { Digest::MD5::md5_base64($_[0]) };
        }
    }
    # default is disabled
    else {
        $self->{'enable_key_hashing'} = 0;
        $self->{'key_hash_method'} = undef;
    }

    # TODO: undocumented
    $self->{'connect_timeout'} = $args->{'connect_timeout'} || 0.25;
    $self->{'select_timeout'}  = $args->{'select_timeout'}  || 1.0;
    $self->{namespace} = $args->{namespace} || '';
    $self->{namespace_len} = length $self->{namespace};

    return $self;
}

sub set_pref_ip {
    my Cache::Memcached $self = shift;
    $self->{'pref_ip'} = shift;
}

sub set_servers {
    my Cache::Memcached $self = shift;
    my ($list) = @_;
    $self->{'servers'} = $list || [];
    $self->{'active'} = scalar @{$self->{'servers'}};
    $self->{'buckets'} = undef;
    $self->{'bucketcount'} = 0;
    $self->init_buckets;

    # We didn't close any sockets, so we reset the buck2sock generation, not increment the global socket cache generation.
    $self->{'buck2sock_generation'} = 0;

    $self->{'_single_sock'} = undef;
    if (@{$self->{'servers'}} == 1) {
        $self->{'_single_sock'} = $self->{'servers'}[0];
    }

    return $self;
}

sub set_cb_connect_fail {
    my Cache::Memcached $self = shift;
    $self->{'cb_connect_fail'} = shift;
}

sub set_connect_timeout {
    my Cache::Memcached $self = shift;
    $self->{'connect_timeout'} = shift;
}

sub set_debug {
    my Cache::Memcached $self = shift;
    my ($dbg) = @_;
    $self->{'debug'} = $dbg || 0;
}

sub set_readonly {
    my Cache::Memcached $self = shift;
    my ($ro) = @_;
    $self->{'readonly'} = $ro;
}

sub set_norehash {
    my Cache::Memcached $self = shift;
    my ($val) = @_;
    $self->{'no_rehash'} = $val;
}

sub set_compress_threshold {
    my Cache::Memcached $self = shift;
    my ($thresh) = @_;
    $self->{'compress_threshold'} = $thresh;
}

sub set_compress_ratio {
    my Cache::Memcached $self = shift;
    my ($ratio) = @_;
    $self->{'compress_ratio'} = $ratio;
}

sub set_max_size {
    my Cache::Memcached $self = shift;
    my ($size) = @_;
    $self->{'max_size'} = $size;
}

sub enable_compress {
    my Cache::Memcached $self = shift;
    my ($enable) = @_;
    $self->{'compress_enable'} = $enable;
}

sub set_compress_enable {
    my Cache::Memcached $self = shift;
    my ($enable) = @_;
    $self->{'compress_enable'} = $enable;
}

sub enable_key_hashing {
    my Cache::Memcached $self = shift;
    my ($enable) = @_;
    # no effect if key_hash_method is not set
    if (ref $self->{'key_hash_method'}) {
        $self->{'enable_key_hashing'} = $enable;
    } else {
        $self->{'enable_key_hashing'} = 0;
    }
}

sub set_key_hash_method {
    my Cache::Memcached $self = shift;
    my ($subref) = @_;
    if (ref $subref) {
        $self->{'key_hash_method'} = $subref;
    } else {
        warn "key_hash_method() called with invalid value (not a subref). Disabling.";
        $self->enable_key_hashing(0);
        $self->{'key_hash_method'} = undef
    }
}

sub set_compress_methods {
    my Cache::Memcached $self = shift;
    my $meth_array = $_[0];
    $meth_array = [@_] unless ref $meth_array eq 'ARRAY';

    if (@$meth_array != 2) {
        warn "compress_methods() called with illegal number of arguments. Disabling.";
        $self->{'compress_methods'} = undef
    } elsif ( ! (ref $meth_array->[0] && ref $meth_array->[1]) ) {
        warn "compress_methods() called with illegal arguments (not code references). Disabling.";
        $self->{'compress_methods'} = undef
    } else {
        $self->{'compress_methods'} = $meth_array;
    }
}

sub set_serialize_methods {
    my Cache::Memcached $self = shift;
    my $meth_array = $_[0];
    $meth_array = [@_] unless ref $meth_array eq 'ARRAY';

    if (@$meth_array != 2) {
        warn "serialize_methods() called with illegal number of arguments. Disabling.";
        $self->{'serialize_methods'} = undef
    } elsif ( ! (ref $meth_array->[0] && ref $meth_array->[1]) ) {
        warn "serialize_methods() called with illegal arguments (not code references). Disabling.";
        $self->{'serialize_methods'} = undef
    } else {
        $self->{'serialize_methods'} = $meth_array;
    }
}

sub forget_dead_hosts {
    my Cache::Memcached $self = shift;
    %host_dead = ();

    # We need to globally recalculate our buck2sock in all objects, so we increment the global generation.
    $socket_cache_generation++;

    return 1;
}

sub set_stat_callback {
    my Cache::Memcached $self = shift;
    my ($stat_callback) = @_;
    $self->{'stat_callback'} = $stat_callback;
}

my %sock_map;  # stringified-$sock -> "$ip:$port"

sub _dead_sock {
    my ($self, $sock, $ret, $dead_for) = @_;
    if (my $ipport = $sock_map{$sock}) {
        my $now = time();
        $host_dead{$ipport} = $now + $dead_for
            if $dead_for;
        delete $cache_sock{$ipport};
        delete $sock_map{$sock};
    }
    # We need to globally recalculate our buck2sock in all objects, so we increment the global generation.
    $socket_cache_generation++;

    return $ret;  # 0 or undef, probably, depending on what caller wants
}

sub _close_sock {
    my ($self, $sock) = @_;
    if (my $ipport = $sock_map{$sock}) {
        close $sock;
        delete $cache_sock{$ipport};
        delete $sock_map{$sock};
    }

    # We need to globally recalculate our buck2sock in all objects, so we increment the global generation.
    $socket_cache_generation++;

    return 1;
}

sub _connect_sock { # sock, sin, timeout
    my ($sock, $sin, $timeout) = @_;
    $timeout = 0.25 if not defined $timeout;

    # make the socket non-blocking from now on,
    # except if someone wants 0 timeout, meaning
    # a blocking connect, but even then turn it
    # non-blocking at the end of this function

    if ($timeout) {
        IO::Handle::blocking($sock, 0);
    } else {
        IO::Handle::blocking($sock, 1);
    }

    my $ret = connect($sock, $sin);

    if (!$ret && $timeout && $!==EINPROGRESS) {

        my $win='';
        vec($win, fileno($sock), 1) = 1;

        if (select(undef, $win, undef, $timeout) > 0) {
            $ret = connect($sock, $sin);
            # EISCONN means connected & won't re-connect, so success
            $ret = 1 if !$ret && $!==EISCONN;
        }
    }

    unless ($timeout) { # socket was temporarily blocking, now revert
        IO::Handle::blocking($sock, 0);
    }

    # from here on, we use non-blocking (async) IO for the duration
    # of the socket's life

    return $ret;
}

sub sock_to_host { # (host)  #why is this public? I wouldn't have to worry about undef $self if it weren't.
    my Cache::Memcached $self = ref $_[0] ? shift : undef;
    my $host = $_[0];
    return $cache_sock{$host} if $cache_sock{$host};

    my $now = time();
    my ($ip, $port) = $host =~ /(.*):(\d+)$/;
    if (defined($ip)) {
        $ip =~ s/[\[\]]//g;  # get rid of optional IPv6 brackets
    }

    return undef if
        $host_dead{$host} && $host_dead{$host} > $now;
    my $sock;

    my $connected = 0;
    my $sin;
    my $proto = $PROTO_TCP ||= getprotobyname('tcp');

    if ( index($host, '/') != 0 )
    {
        # if a preferred IP is known, try that first.
        if ($self && $self->{pref_ip}{$ip}) {
            my $prefip = $self->{pref_ip}{$ip};
            if ($HAVE_SOCKET6 && index($prefip, ':') != -1) {
                no strict 'subs';  # for PF_INET6 and AF_INET6, weirdly imported
                socket($sock, PF_INET6, SOCK_STREAM, $proto);
                $sock_map{$sock} = $host;
                $sin = Socket6::pack_sockaddr_in6($port,
                                                  Socket6::inet_pton(AF_INET6, $prefip));
            } else {
                socket($sock, PF_INET, SOCK_STREAM, $proto);
                $sock_map{$sock} = $host;
                $sin = Socket::sockaddr_in($port, Socket::inet_aton($prefip));
            }

            if (_connect_sock($sock,$sin,$self->{connect_timeout})) {
                $connected = 1;
            } else {
                if (my $cb = $self->{cb_connect_fail}) {
                    $cb->($prefip);
                }
                close $sock;
            }
        }

        # normal path, or fallback path if preferred IP failed
        unless ($connected) {
            if ($HAVE_SOCKET6 && index($ip, ':') != -1) {
                no strict 'subs';  # for PF_INET6 and AF_INET6, weirdly imported
                socket($sock, PF_INET6, SOCK_STREAM, $proto);
                $sock_map{$sock} = $host;
                $sin = Socket6::pack_sockaddr_in6($port,
                                                  Socket6::inet_pton(AF_INET6, $ip));
            } else {
                socket($sock, PF_INET, SOCK_STREAM, $proto);
                $sock_map{$sock} = $host;
                $sin = Socket::sockaddr_in($port, Socket::inet_aton($ip));
            }

            my $timeout = $self ? $self->{connect_timeout} : 0.25;
            unless (_connect_sock($sock, $sin, $timeout)) {
                my $cb = $self ? $self->{cb_connect_fail} : undef;
                $cb->($ip) if $cb;
                return _dead_sock($self, $sock, undef, 20 + int(rand(10)));
            }
        }
    } else { # it's a unix domain/local socket
        socket($sock, PF_UNIX, SOCK_STREAM, 0);
        $sock_map{$sock} = $host;
        $sin = Socket::sockaddr_un($host);
        my $timeout = $self ? $self->{connect_timeout} : 0.25;
        unless (_connect_sock($sock,$sin,$timeout)) {
            my $cb = $self ? $self->{cb_connect_fail} : undef;
            $cb->($host) if $cb;
            return _dead_sock($self, $sock, undef, 20 + int(rand(10)));
        }
    }

    # make the new socket not buffer writes.
    my $old = select($sock);
    $| = 1;
    select($old);

    $cache_sock{$host} = $sock;

    return $sock;
}

sub get_sock { # (key)
    my Cache::Memcached $self = $_[0];
    my $key = $_[1];
    return $self->sock_to_host($self->{'_single_sock'}) if $self->{'_single_sock'};
    return undef unless $self->{'active'};

    my $real_key = ref $key ? $key->[1] : $key;
    $real_key = $self->{'key_hash_method'}->( $real_key ) if $self->{'enable_key_hashing'};
    my $hv = ref $key ? int($key->[0]) : _hashfunc($real_key);

    my $tries = 0;
    while ($tries++ < 20) {
        my $host = $self->{'buckets'}->[$hv % $self->{'bucketcount'}];
        my $sock = $self->sock_to_host($host);
        return $sock if $sock;
        return undef if $self->{'no_rehash'};
        $hv += _hashfunc($tries . $real_key);  # stupid, but works
    }
    return undef;
}

sub init_buckets {
    my Cache::Memcached $self = shift;
    return if $self->{'buckets'};
    my $bu = $self->{'buckets'} = [];
    foreach my $v (@{$self->{'servers'}}) {
        if (ref $v eq "ARRAY") {
            for (1..$v->[1]) { push @$bu, $v->[0]; }
        } else {
            push @$bu, $v;
        }
    }
    $self->{'bucketcount'} = scalar @{$self->{'buckets'}};
}

sub disconnect_all {
    my Cache::Memcached $self = shift;
    my $sock;
    foreach $sock (values %cache_sock) {
        close $sock;
    }
    %cache_sock = ();

    # We need to globally recalculate our buck2sock in all objects, so we increment the global generation.
    $socket_cache_generation++;
}

# writes a line, then reads result.  by default stops reading after a
# single line, but caller can override the $check_complete subref,
# which gets passed a scalarref of buffer read thus far.
sub _write_and_read {
    my Cache::Memcached $self = shift;
    my ($sock, $line, $check_complete) = @_;
    my $res;
    my ($ret, $offset) = (undef, 0);

    $check_complete ||= sub {
        return (rindex($ret, "\r\n") + 2 == length($ret));
    };

    # state: 0 - writing, 1 - reading, 2 - done
    my $state = 0;

    # the bitsets for select
    my ($rin, $rout, $win, $wout);
    my $nfound;

    my $copy_state = -1;
    local $SIG{'PIPE'} = "IGNORE" unless $FLAG_NOSIGNAL;

    # the select loop
    while(1) {
        if ($copy_state!=$state) {
            last if $state==2;
            ($rin, $win) = ('', '');
            vec($rin, fileno($sock), 1) = 1 if $state==1;
            vec($win, fileno($sock), 1) = 1 if $state==0;
            $copy_state = $state;
        }
        $nfound = select($rout=$rin, $wout=$win, undef,
                         $self->{'select_timeout'});
        last unless $nfound;

        if (vec($wout, fileno($sock), 1)) {
            $res = send($sock, $line, $FLAG_NOSIGNAL);
            next
                if not defined $res and $!==EWOULDBLOCK;
            unless ($res > 0) {
                $self->_close_sock($sock);
                return undef;
            }
            if ($res == length($line)) { # all sent
                $state = 1;
            } else { # we only succeeded in sending some of it
                substr($line, 0, $res, ''); # delete the part we sent
            }
        }

        if (vec($rout, fileno($sock), 1)) {
            $res = sysread($sock, $ret, 255, $offset);
            next
                if !defined($res) and $!==EWOULDBLOCK;
            if ($res == 0) { # catches 0=conn closed or undef=error
                $self->_close_sock($sock);
                return undef;
            }
            $offset += $res;
            $state = 2 if $check_complete->(\$ret);
        }
    }

    unless ($state == 2) {
        $self->_dead_sock($sock); # improperly finished
        return undef;
    }

    return $ret;
}

sub delete {
    my Cache::Memcached $self = shift;
    my ($key, $time) = @_;
    return 0 if ! $self->{'active'} || $self->{'readonly'};
    my $stime = Time::HiRes::time() if $self->{'stat_callback'};
    my $sock = $self->get_sock($key);
    return 0 unless $sock;

    $self->{'stats'}->{"delete"}++;
    $key = ref $key ? $key->[1] : $key;
    $key = $self->{'key_hash_method'}->( $key ) if $self->{'enable_key_hashing'};
    $time = $time ? " $time" : "";

    # key reconstituted from server won't have utf8 on, so turn it off on input
    # scalar to allow hash lookup to succeed
    Encode::_utf8_off($key) if Encode::is_utf8($key);

    my $cmd = "delete $self->{namespace}$key$time\r\n";
    my $res = _write_and_read($self, $sock, $cmd);

    if ($self->{'stat_callback'}) {
        my $etime = Time::HiRes::time();
        $self->{'stat_callback'}->($stime, $etime, $sock, 'delete');
    }

    return defined $res && $res eq "DELETED\r\n";
}
*remove = \&delete;

sub add {
    _set("add", @_);
}

sub replace {
    _set("replace", @_);
}

sub set {
    _set("set", @_);
}

sub append {
    _set("append", @_);
}

sub prepend {
    _set("prepend", @_);
}

sub _set {
    my $cmdname = shift;
    my Cache::Memcached $self = shift;
    my ($key, $val, $exptime) = @_;
    return 0 if ! $self->{'active'} || $self->{'readonly'};
    my $stime = Time::HiRes::time() if $self->{'stat_callback'};
    my $sock = $self->get_sock($key);
    return 0 unless $sock;

    use bytes; # return bytes from length()

    my $app_or_prep = $cmdname eq 'append' || $cmdname eq 'prepend' ? 1 : 0;
    $self->{'stats'}->{$cmdname}++;
    my $flags = 0;
    my $real_key = $key = ref $key ? $key->[1] : $key;
    $key = $self->{'key_hash_method'}->( $key ) if $self->{'enable_key_hashing'};

    if (ref $val) {
        die "append or prepend cannot take a reference" if $app_or_prep;
        local $Carp::CarpLevel = 3;
        $val = eval { &{ $self->{'serialize_methods'}[0] }( $val ) };
        $flags |= F_STORABLE;
    }
    warn "value for memkey:$real_key is not defined" unless defined $val;

    my $len = length($val);

    if ($self->{'compress_threshold'} && $self->{'compress_enable'} &&
        $self->{'compress_methods'}   && !$app_or_prep &&
        $len >= $self->{'compress_threshold'}) {

        # wrap compress method in eval - it could be passed by the user and buggy
        my $c_val;
        eval {
            &{ $self->{'compress_methods'}[0] }( \$val, \$c_val );
        };
        # if there was a problem, skip it
        if ($@) {
            print STDERR "compress_methods 0 (compress) failed: $@\n" if $self->{'debug'};
        } else {
            my $c_len = length($c_val);
            # do we want to keep it?
            if ($c_len < $len*$self->{'compress_ratio'}) {
                $val = $c_val;
                $len = $c_len;
                $flags |= F_COMPRESS;
            }
        }
    }

    if ($self->{'max_size'} && $len > $self->{'max_size'}) {
        return; # mirror behavior of Cache::Memcached::Fast
        # return 0; behave as other failures in Cache::Memcached
        # return 1; "too_big_threshold" behavor from https://rt.cpan.org/Ticket/Display.html?id=35611
    }

    $exptime = int($exptime || 0);

    local $SIG{'PIPE'} = "IGNORE" unless $FLAG_NOSIGNAL;
    my $line = "$cmdname $self->{namespace}$key $flags $exptime $len\r\n$val\r\n";

    my $res = _write_and_read($self, $sock, $line);

    if ($self->{'debug'} && $line) {
        chop $line; chop $line;
        print STDERR "Cache::Memcache: $cmdname $self->{namespace}$key = $val ($line)\n";
    }

    if ($self->{'stat_callback'}) {
        my $etime = Time::HiRes::time();
        $self->{'stat_callback'}->($stime, $etime, $sock, $cmdname);
    }

    return defined $res && $res eq "STORED\r\n";
}

sub incr {
    _incrdecr("incr", @_);
}

sub decr {
    _incrdecr("decr", @_);
}

sub _incrdecr {
    my $cmdname = shift;
    my Cache::Memcached $self = shift;
    my ($key, $value) = @_;
    return undef if ! $self->{'active'} || $self->{'readonly'};
    my $stime = Time::HiRes::time() if $self->{'stat_callback'};
    my $sock = $self->get_sock($key);
    return undef unless $sock;
    $key = $key->[1] if ref $key;
    $key = $self->{'key_hash_method'}->( $key ) if $self->{'enable_key_hashing'};
    $self->{'stats'}->{$cmdname}++;
    $value = 1 unless defined $value;

    my $line = "$cmdname $self->{namespace}$key $value\r\n";
    my $res = _write_and_read($self, $sock, $line);

    if ($self->{'stat_callback'}) {
        my $etime = Time::HiRes::time();
        $self->{'stat_callback'}->($stime, $etime, $sock, $cmdname);
    }

    return undef unless defined $res && $res =~ /^(\d+)/;
    return $1;
}

sub get {
    my Cache::Memcached $self = $_[0];
    my $key = $_[1];

    # TODO: make a fast path for this?  or just keep using get_multi?
    my $r = $self->get_multi($key);
    my $kval = ref $key ? $key->[1] : $key;

    # key reconstituted from server won't have utf8 on, so turn it off on input
    # scalar to allow hash lookup to succeed
    Encode::_utf8_off($kval) if Encode::is_utf8($kval);

    return $r->{$kval};
}

sub get_multi {
    my Cache::Memcached $self = shift;
    return {} unless $self->{'active'};
    $self->{'_stime'} = Time::HiRes::time() if $self->{'stat_callback'};
    $self->{'stats'}->{"get_multi"}++;

    my %val;        # what we'll be returning a reference to (realkey -> value)
    my %sock_keys;  # sockref_as_scalar -> [ realkeys ]
    my $sock;

    # build reverse lookup to map hashed keys back to user provided values
    # ... cache the reverse do we do not have to call the digest methods twice
    my %hash_to_key_map;
    my %key_to_hash_map;
    if ($self->{'enable_key_hashing'}) {
        %hash_to_key_map = map { $self->{'key_hash_method'}->( $_ ) => $_ } @_;
        %key_to_hash_map = map { $hash_to_key_map{$_} => $_ } keys %hash_to_key_map;
    }

    if ($self->{'_single_sock'}) {
        $sock = $self->sock_to_host($self->{'_single_sock'});
        unless ($sock) {
            return {};
        }
        foreach my $key (@_) {
            my $kval = ref $key ? $key->[1] : $key;
            $kval = $key_to_hash_map{ $kval } if $self->{'enable_key_hashing'};
            push @{$sock_keys{$sock}}, $kval;
        }
    } else {
        my $bcount = $self->{'bucketcount'};
        my $sock;

        if ($self->{'buck2sock_generation'} != $socket_cache_generation) {
            $self->{'buck2sock_generation'} = $socket_cache_generation;
            $self->{'buck2sock'} = [];
        }

      KEY:
        foreach my $key (@_) {
            my $real_key = ref $key ? $key->[1] : $key;
            $real_key = $key_to_hash_map{ $real_key } if $self->{'enable_key_hashing'};
            my $hv = ref $key ? int($key->[0]) : _hashfunc($real_key);

            my $tries;
            while (1) {
                my $bucket = $hv % $bcount;

                # this segfaults perl 5.8.4 (and others?) if sock_to_host returns undef... wtf?
                #$sock = $buck2sock[$bucket] ||= $self->sock_to_host($self->{buckets}[ $bucket ])
                #    and last;

                # but this variant doesn't crash:
                $sock = $self->{'buck2sock'}->[$bucket] || $self->sock_to_host($self->{buckets}[ $bucket ]);
                if ($sock) {
                    $self->{'buck2sock'}->[$bucket] = $sock;
                    last;
                }

                next KEY if $tries++ >= 20;
                $hv += _hashfunc($tries . $real_key);
            }

            push @{$sock_keys{$sock}}, $real_key;
        }
    }

    $self->{'stats'}->{"get_keys"} += @_;
    $self->{'stats'}->{"get_socks"} += keys %sock_keys;

    local $SIG{'PIPE'} = "IGNORE" unless $FLAG_NOSIGNAL;

    _load_multi($self, \%sock_keys, \%val);

    # map the hashed keys back to user provided key values
    if ($self->{'enable_key_hashing'}) {
        foreach my $k (keys %val) {
            $val{ $hash_to_key_map{$k} } = delete $val{$k};
        }
    }

    if ($self->{'debug'}) {
        while (my ($k, $v) = each %val) {
            print STDERR "MemCache: got $k = $v\n";
        }
    }
    return \%val;
}

sub _load_multi {
    use bytes; # return bytes from length()
    my Cache::Memcached $self;
    my ($sock_keys, $ret);

    ($self, $sock_keys, $ret) = @_;

    # all keyed by $sockstr:
    my %reading; # $sockstr -> $sock.  bool, whether we're reading from this socket
    my %writing; # $sockstr -> $sock.  bool, whether we're writing to this socket
    my %buf;     # buffers, for writing

    my %parser;  # $sockstr -> Cache::Memcached::GetParser

    my $active_changed = 1; # force rebuilding of select sets

    my $dead = sub {
        my $sock = shift;
        print STDERR "killing socket $sock\n" if $self->{'debug'} >= 2;
        delete $reading{$sock};
        delete $writing{$sock};

        if (my $p = $parser{$sock}) {
            my $key = $p->current_key;
            delete $ret->{$key} if $key;
        }

        if ($self->{'stat_callback'}) {
            my $etime = Time::HiRes::time();
            $self->{'stat_callback'}->($self->{'_stime'}, $etime, $sock, 'get_multi');
        }

        close $sock;
        $self->_dead_sock($sock);
    };

    # $finalize->($key, $flags)
    # $finalize->({ $key => $flags, $key => $flags });
    my $finalize = sub {
        my $map = $_[0];
        $map = {@_} unless ref $map;

        while (my ($k, $flags) = each %$map) {

            # remove trailing \r\n
            chop $ret->{$k}; chop $ret->{$k};

            if ($flags & F_COMPRESS && $self->{'compress_methods'}) {
                my $r_val;
                # wrap compress method in eval - it could be passed by the user and buggy
                eval {
                    &{ $self->{'compress_methods'}[1] }( \$ret->{$k} , \$r_val );
                };
                # use it if it worked, or set to undef
                # XXX: that's what Compress::Zlib::memGunzip failures would do
                if ($@) {
                    print STDERR "compress_methods 1 (decompress) failed: $@\n" if $self->{'debug'};
                    $ret->{$k} = undef;
                } else {
                    $ret->{$k} = $r_val;
                }
            }
            if ($flags & F_STORABLE) {
                # wrapped in eval in case a perl 5.6 Storable tries to
                # unthaw data from a perl 5.8 Storable.  (5.6 is stupid
                # and dies if the version number changes at all.  in 5.8
                # they made it only die if it unencounters a new feature)
                eval {
                    $ret->{$k} = &{ $self->{'serialize_methods'}[1] }( $ret->{$k} );
                };
                # so if there was a problem, just treat it as a cache miss.
                if ($@) {
                    delete $ret->{$k};
                }
            }
        }
    };

    foreach (keys %$sock_keys) {
        my $ipport = $sock_map{$_}        or die "No map found matching for $_";
        my $sock   = $cache_sock{$ipport} or die "No sock found for $ipport";
        print STDERR "processing socket $_\n" if $self->{'debug'} >= 2;
        $writing{$_} = $sock;
        if ($self->{namespace}) {
            $buf{$_} = join(" ", 'get', (map { "$self->{namespace}$_" } @{$sock_keys->{$_}}), "\r\n");
        } else {
            $buf{$_} = join(" ", 'get', @{$sock_keys->{$_}}, "\r\n");
        }

        $parser{$_} = $self->{parser_class}->new($ret, $self->{namespace_len}, $finalize);
    }

    my $read = sub {
        my $sockstr = "$_[0]";  # $sock is $_[0];
        my $p = $parser{$sockstr} or die;
        my $rv = $p->parse_from_sock($_[0]);
        if ($rv > 0) {
            # okay, finished with this socket
            delete $reading{$sockstr};
        } elsif ($rv < 0) {
            $dead->($_[0]);
        }
        return $rv;
    };

    # returns 1 when it's done, for success or error.  0 if still working.
    my $write = sub {
        my ($sock, $sockstr) = ($_[0], "$_[0]");
        my $res;

        $res = send($sock, $buf{$sockstr}, $FLAG_NOSIGNAL);

        return 0
            if not defined $res and $!==EWOULDBLOCK;
        unless ($res > 0) {
            $dead->($sock);
            return 1;
        }
        if ($res == length($buf{$sockstr})) { # all sent
            $buf{$sockstr} = "";

            # switch the socket from writing to reading
            delete $writing{$sockstr};
            $reading{$sockstr} = $sock;
            return 1;
        } else { # we only succeeded in sending some of it
            substr($buf{$sockstr}, 0, $res, ''); # delete the part we sent
        }
        return 0;
    };

    # the bitsets for select
    my ($rin, $rout, $win, $wout);
    my $nfound;

    # the big select loop
    while(1) {
        if ($active_changed) {
            last unless %reading or %writing; # no sockets left?
            ($rin, $win) = ('', '');
            foreach (values %reading) {
                vec($rin, fileno($_), 1) = 1;
            }
            foreach (values %writing) {
                vec($win, fileno($_), 1) = 1;
            }
            $active_changed = 0;
        }
        # TODO: more intelligent cumulative timeout?
        # TODO: select is interruptible w/ ptrace attach, signal, etc. should note that.
        $nfound = select($rout=$rin, $wout=$win, undef,
                         $self->{'select_timeout'});
        last unless $nfound;

        # TODO: possible robustness improvement: we could select
        # writing sockets for reading also, and raise hell if they're
        # ready (input unread from last time, etc.)
        # maybe do that on the first loop only?
        foreach (values %writing) {
            if (vec($wout, fileno($_), 1)) {
                $active_changed = 1 if $write->($_);
            }
        }
        foreach (values %reading) {
            if (vec($rout, fileno($_), 1)) {
                $active_changed = 1 if $read->($_);
            }
        }
    }

    # if there're active sockets left, they need to die
    foreach (values %writing) {
        $dead->($_);
    }
    foreach (values %reading) {
        $dead->($_);
    }

    return;
}

sub _hashfunc {
    return (crc32($_[0]) >> 16) & 0x7fff;
}

sub flush_all {
    my Cache::Memcached $self = shift;

    my $success = 1;

    my @hosts = @{$self->{'buckets'}};
    foreach my $host (@hosts) {
        my $sock = $self->sock_to_host($host);
        my @res = $self->run_command($sock, "flush_all\r\n");
        $success = 0 unless (scalar @res == 1 && (($res[0] || "") eq "OK\r\n"));
    }

    return $success;
}

# returns array of lines, or () on failure.
sub run_command {
    my Cache::Memcached $self = shift;
    my ($sock, $cmd) = @_;
    return () unless $sock;
    my $ret;
    my $line = $cmd;
    while (my $res = _write_and_read($self, $sock, $line)) {
        undef $line;
        $ret .= $res;
        last if $ret =~ /(?:OK|END|ERROR)\r\n$/;
    }
    chop $ret; chop $ret;
    return map { "$_\r\n" } split(/\r\n/, $ret);
}

sub stats {
    my Cache::Memcached $self = shift;
    my ($types) = @_;
    return 0 unless $self->{'active'};
    return 0 unless !ref($types) || ref($types) eq 'ARRAY';
    if (!ref($types)) {
        if (!$types) {
            # I don't much care what the default is, it should just
            # be something reasonable.  Obviously "reset" should not
            # be on the list :) but other types that might go in here
            # include maps, cachedump, slabs, or items.  Note that
            # this does NOT include 'sizes' anymore, as that can freeze
            # bug servers for a couple seconds.
            $types = [ qw( misc malloc self ) ];
        } else {
            $types = [ $types ];
        }
    }

    my $stats_hr = { };

    # The "self" stat type is special, it only applies to this very
    # object.
    if (grep /^self$/, @$types) {
        $stats_hr->{'self'} = \%{ $self->{'stats'} };
    }

    my %misc_keys = map { $_ => 1 }
      qw/ bytes bytes_read bytes_written
          cmd_get cmd_set connection_structures curr_items
          get_hits get_misses
          total_connections total_items
        /;

    # Now handle the other types, passing each type to each host server.
    my @hosts = @{$self->{'buckets'}};
  HOST: foreach my $host (@hosts) {
        my $sock = $self->sock_to_host($host);
        next HOST unless $sock;
      TYPE: foreach my $typename (grep !/^self$/, @$types) {
            my $type = $typename eq 'misc' ? "" : " $typename";
            my $lines = _write_and_read($self, $sock, "stats$type\r\n", sub {
                my $bref = shift;
                return $$bref =~ /^(?:END|ERROR)\r?\n/m;
            });
            unless ($lines) {
                $self->_dead_sock($sock);
                next HOST;
            }

            $lines =~ s/\0//g;  # 'stats sizes' starts with NULL?

            # And, most lines end in \r\n but 'stats maps' (as of
            # July 2003 at least) ends in \n. ??
            my @lines = split(/\r?\n/, $lines);

            # Some stats are key-value, some are not.  malloc,
            # sizes, and the empty string are key-value.
            # ("self" was handled separately above.)
            if ($typename =~ /^(malloc|sizes|misc)$/) {
                # This stat is key-value.
                foreach my $line (@lines) {
                    my ($key, $value) = $line =~ /^(?:STAT )?(\w+)\s(.*)/;
                    if ($key) {
                        $stats_hr->{'hosts'}{$host}{$typename}{$key} = $value;
                    }
                    $stats_hr->{'total'}{$key} += $value
                        if $typename eq 'misc' && $key && $misc_keys{$key};
                    $stats_hr->{'total'}{"malloc_$key"} += $value
                        if $typename eq 'malloc' && $key;
                }
            } else {
                # This stat is not key-value so just pull it
                # all out in one blob.
                $lines =~ s/^END\r?\n//m;
                $stats_hr->{'hosts'}{$host}{$typename} ||= "";
                $stats_hr->{'hosts'}{$host}{$typename} .= "$lines";
            }
        }
    }

    return $stats_hr;
}

sub stats_reset {
    my Cache::Memcached $self = shift;
    my ($types) = @_;
    return 0 unless $self->{'active'};

  HOST: foreach my $host (@{$self->{'buckets'}}) {
        my $sock = $self->sock_to_host($host);
        next HOST unless $sock;
        my $ok = _write_and_read($self, $sock, "stats reset");
        unless (defined $ok && $ok eq "RESET\r\n") {
            $self->_dead_sock($sock);
        }
    }
    return 1;
}

1;
__END__

=head1 NAME

Cache::Memcached - client library for memcached (memory cache daemon)

=head1 SYNOPSIS

  use Cache::Memcached;

  $memd = new Cache::Memcached {
    'servers' => [ "10.0.0.15:11211", "10.0.0.15:11212", "/var/sock/memcached",
                   "10.0.0.17:11211", [ "10.0.0.17:11211", 3 ] ],
    'debug'              => 0,
    'namespace'          => '',
    'connect_timeout'    => 0.25,
    'select_timeout'     => 1,
    'compress_enable'    => 1,
    'compress_threshold' => 10_000,
    'compress_ratio'     => 0.8,
    'compress_methods'   => [ sub { ${$_[1]} = Compress::Zlib::memGzip(${$_[0]})   },
                              sub { ${$_[1]} = Compress::Zlib::memGunzip(${$_[0]}) }, ],
    'serialize_methods'  => [ \&Storable::nfreeze, \&Storable::thaw ],
    'enable_key_hashing' => 0,
    'key_hash_method'    => sub { Digest::MD5::md5_base64( $_ ) },
    'max_size'           => 0,
  };
  $memd->set_servers($array_ref);
  $memd->set_compress_threshold(10_000);
  $memd->enable_compress(0);

  $memd->set("my_key", "Some value");
  $memd->set("object_key", { 'complex' => [ "object", 2, 4 ]});

  $val = $memd->get("my_key");
  $val = $memd->get("object_key");
  if ($val) { print $val->{'complex'}->[2]; }

  $memd->incr("key");
  $memd->decr("key");
  $memd->incr("key", 2);

=head1 DESCRIPTION

This is the Perl API for memcached, a distributed memory cache daemon.
More information is available at:

  http://www.danga.com/memcached/

=head1 CONSTRUCTOR

=over 4

=item C<new>

Takes one parameter, a hashref of options.  The most important key is
C<servers>, but that can also be set later with the C<set_servers>
method.  The servers must be an arrayref of hosts, each of which is
either a scalar of the form C<10.0.0.10:11211> or an arrayref of the
former and an integer weight value.  (The default weight if
unspecified is 1.)  It's recommended that weight values be kept as low
as possible, as this module currently allocates memory for bucket
distribution proportional to the total host weights.

Use C<compress_enable> to enable/disable compression of values.
Default is 1, enabled.
NOTE: passing "undef" is not recognized as disable. Pass 0 to disable.

Use C<compress_threshold> to set a compression threshold, in bytes.
Values larger than this threshold will be compressed by C<set> and
decompressed by C<get>.

Use C<compress_ratio> to set the minimum amount of compression that
will be considered usable.
The value is a fractional number between 0 and 1. When L</compress_threshold>
triggers the compression, compressed size should be less or equal to
S<(original-size * I<compress_ratio>)>.
Otherwise the data will be stored uncompressed.

Use C<no_rehash> to disable finding a new memcached server when one
goes down.  Your application may or may not need this, depending on
your expirations and key usage.

Use C<readonly> to disable writes to backend memcached servers.  Only
get and get_multi will work.  This is useful in bizarre debug and
profiling cases only.

Use C<namespace> to prefix all keys with the provided namespace value.
That is, if you set namespace to "app1:" and later do a set of "foo"
to "bar", memcached is actually seeing you set "app1:foo" to "bar".

Use C<connect_timeout> and C<select_timeout> to set connection and
polling timeouts. The C<connect_timeout> defaults to .25 second, and
the C<select_timeout> defaults to 1 second.

Use C<compress_methods> to set custom compression/decompression
methods. See L</set_compress_methods> for more information.

Use C<serialize_methods> to set custom freeze/thaw
methods. See L</set_serialize_methods> for more information.

Use C<enable_key_hasing> to transparently use a one way hash
(ex. Digest::MD5::md5_base64) for the key stored on the memcached servers.
See L</enable_key_hasing> for more information.

Use C<key_hash_method> to set the method used to internally hash
keys. See L</set_key_hash_method> for more information.

Use C<max_size> to set the maximum size of an item to be stored in memcached.
See L</set_max_size> for more information.

The other useful key is C<debug>, which when set to true will produce
diagnostics on STDERR.

=back

=head1 METHODS

=over 4

=item C<set_servers>

Sets the server list this module distributes key gets and sets between.
The format is an arrayref of identical form as described in the C<new>
constructor.

=item C<set_debug>

Sets the C<debug> flag.  See C<new> constructor for more information.

=item C<set_readonly>

Sets the C<readonly> flag.  See C<new> constructor for more information.

=item C<set_norehash>

Sets the C<no_rehash> flag.  See C<new> constructor for more information.

=item C<set_compress_threshold>

Sets the compression threshold. See C<new> constructor for more information.

=item C<set_compress_ratio>

Sets the minimum compression ratio. See C<new> constructor for more information.

=item C<set_connect_timeout>

Sets the connect timeout. See C<new> constructor for more information.

=item C<set_select_timeout>

Sets the select timeout. See C<new> constructor for more information.

=item C<enable_compress>

Temporarily enable or disable compression.  Has no effect if C<compress_threshold>
isn't set, but has an overriding effect if it is.

=item C<set_compress_enable>

Alias for L</enable_compress>.

=item C<enable_key_hashing>

Enable to disable mapping keys to a hash (ex. Digest::MD5::md5_base64($key)).
Has no effect unless C<key_hash_method> is set to a usable value.

This enables the use of arbitrarily large keys. The memcached protocol
supports a maximum key size of 250 bytes. Using an md5_base64 of the
key uses only 22 bytes + length of your chosen namespace string, 
regardless of the size of the key you use. Using this, you can build
very large and verbose keys, and they will still work and will not
hurt network or memcached server performance. L<Digest::MD5> is quite
fast, so its use has very little impact on performance.

This can be used to temporarily enable/disable this feature.

=item C<set_key_hash_method>

  set_key_hash_method( sub { Digest::SHA::sha256_base64($_) } )

From L</new>:

  key_hash_method => sub { Digest::SHA::sha256_base64($_) }
  (default: sub { Digest::MD5::md5_base64($_) })

The value is a code reference applied to all keys before they are
sent to the memcached server.

When L</get_multi> is used, the key values requested will be mapped
back into the return data, so the internal usage of the hashed key
is transparent to the user for all use cases.

NOTE: 

=over

While tempting, this does not allow you to use a hash, array, or
other reference as a key along with L<Storable> in your L</key_hash_method>.
For example, this will not work:

    set_key_hash_method(
        sub { Digest::MD5::md5_base64( ref($_[0]) ? Storable($_[0]) : $_[0] ) }
    );

If you need this sort of functionality, it will need to be implemented
at a higher level. For an example, see L<Cache::Memcached::Managed>.

=back

=item C<set_compress_methods>

  set_compress_methods( [ \&IO::Compress::Gzip::gzip,
                          \&IO::Uncompress::Gunzip::gunzip ] )

From L</new>:

  compress_methods => [ \&IO::Compress::Gzip::gzip,
                        \&IO::Uncompress::Gunzip::gunzip ]
  (default: [ sub { ${$_[1]} = Compress::Zlib::memGzip(${$_[0]}) },
              sub { ${$_[1]} = Compress::Zlib::memGunzip(${$_[0]}) } ]
   when Compress::Zlib is available)

The value is a reference to an array holding two code references for
compression and decompression routines respectively.

Compression routine is called when the size of the I<$value> passed to
L</set> method family is greater than or equal to
L</compress_threshold> (also see L</compress_ratio>).  The fact that
compression was performed is remembered along with the data, and
decompression routine is called on data retrieval with L</get> method
family.  The interface of these routines should be the same as for
B<IO::Compress> family (for instance see
L<IO::Compress::Gzip::gzip|IO::Compress::Gzip/gzip> and
L<IO::Uncompress::Gunzip::gunzip|IO::Uncompress::Gunzip/gunzip>).
I.e. compression routine takes a reference to scalar value and a
reference to scalar where compressed result will be stored.
Decompression routine takes a reference to scalar with compressed data
and a reference to scalar where uncompressed result will be stored.
Both routines should return true on success, and false on error.

By default we use L<Compress::Zlib|Compress::Zlib> because as of this
writing it appears to be much faster than
L<IO::Uncompress::Gunzip|IO::Uncompress::Gunzip>.

=item C<set_serialize_methods>

  set_serialize_methods( [ \&Storable::freeze, \&Storable::thaw ] )

From L</new>:

  serialize_methods => [ \&Storable::freeze, \&Storable::thaw ]
  (default: [ \&Storable::nfreeze, \&Storable::thaw ])

The value is a reference to an array holding two code references for
serialization and deserialization routines respectively.

Serialization routine is called when the I<$value> passed to L</set>
method family is a reference.  The fact that serialization was
performed is remembered along with the data, and deserialization
routine is called on data retrieval with L</get> method family.  The
interface of these routines should be the same as for
L<Storable::nfreeze|Storable/nfreeze> and
L<Storable::thaw|Storable/thaw>.  I.e. serialization routine takes a
reference and returns a scalar string; it should not fail.
Deserialization routine takes scalar string and returns a reference;
if deserialization fails (say, wrong data format) it should throw an
exception (call I<die>).  The exception will be caught by the module
and L</get> will then pretend that the key hasn't been found.

=item C<set_max_size>

  max_size => 1024 * 1024
  (default: 0)

The value is a maximum size of an item to be stored in memcached.
When trying to set a key to a value longer than I<max_size> bytes
(after serialization and compression) nothing is sent to the server,
and I<set> methods return I<undef>.

Note that the real maximum on the server is less than 1MB, and depends
on key length among other things.  So some values in the range
S<I<[1MB - N bytes, 1MB]>>, where N is several hundreds, will still be
sent to the server, and rejected there.  You may set I<max_size> to a
smaller value to avoid this.

Note that L<Cache::Memcached::Fast> defaults to 1024*1024 (1mb).
For backward compatability with previous versions of L<Cache::Memcached>,
the default here is to disable this feature (0).

=item C<get>

my $val = $memd->get($key);

Retrieves a key from the memcache.  Returns the value (automatically
thawed with Storable, if necessary) or undef.

The $key can optionally be an arrayref, with the first element being the
hash value, if you want to avoid making this module calculate a hash
value.  You may prefer, for example, to keep all of a given user's
objects on the same memcache server, so you could use the user's
unique id as the hash value.

=item C<get_multi>

my $hashref = $memd->get_multi(@keys);

Retrieves multiple keys from the memcache doing just one query.
Returns a hashref of key/value pairs that were available.

This method is recommended over regular 'get' as it lowers the number
of total packets flying around your network, reducing total latency,
since your app doesn't have to wait for each round-trip of 'get'
before sending the next one.

=item C<set>

$memd->set($key, $value[, $exptime]);

Unconditionally sets a key to a given value in the memcache.  Returns true
if it was stored successfully.

The $key can optionally be an arrayref, with the first element being the
hash value, as described above.

The $exptime (expiration time) defaults to "never" if unspecified.  If
you want the key to expire in memcached, pass an integer $exptime.  If
value is less than 60*60*24*30 (30 days), time is assumed to be relative
from the present.  If larger, it's considered an absolute Unix time.

=item C<add>

$memd->add($key, $value[, $exptime]);

Like C<set>, but only stores in memcache if the key doesn't already exist.

=item C<replace>

$memd->replace($key, $value[, $exptime]);

Like C<set>, but only stores in memcache if the key already exists.  The
opposite of C<add>.

=item C<delete>

$memd->delete($key[, $time]);

Deletes a key.  You may optionally provide an integer time value (in seconds) to
tell the memcached server to block new writes to this key for that many seconds.
(Sometimes useful as a hacky means to prevent races.)  Returns true if key
was found and deleted, and false otherwise.

You may also use the alternate method name B<remove>, so
Cache::Memcached looks like the L<Cache::Cache> API.

=item C<incr>

$memd->incr($key[, $value]);

Sends a command to the server to atomically increment the value for
$key by $value, or by 1 if $value is undefined.  Returns undef if $key
doesn't exist on server, otherwise it returns the new value after
incrementing.  Value should be zero or greater.  Overflow on server
is not checked.  Be aware of values approaching 2**32.  See decr.

=item C<decr>

$memd->decr($key[, $value]);

Like incr, but decrements.  Unlike incr, underflow is checked and new
values are capped at 0.  If server value is 1, a decrement of 2
returns 0, not -1.

=item C<stats>

$memd->stats([$keys]);

Returns a hashref of statistical data regarding the memcache server(s),
the $memd object, or both.  $keys can be an arrayref of keys wanted, a
single key wanted, or absent (in which case the default value is malloc,
sizes, self, and the empty string).  These keys are the values passed
to the 'stats' command issued to the memcached server(s), except for
'self' which is internal to the $memd object.  Allowed values are:

=over 4

=item C<misc>

The stats returned by a 'stats' command:  pid, uptime, version,
bytes, get_hits, etc.

=item C<malloc>

The stats returned by a 'stats malloc':  total_alloc, arena_size, etc.

=item C<sizes>

The stats returned by a 'stats sizes'.

=item C<self>

The stats for the $memd object itself (a copy of $memd->{'stats'}).

=item C<maps>

The stats returned by a 'stats maps'.

=item C<cachedump>

The stats returned by a 'stats cachedump'.

=item C<slabs>

The stats returned by a 'stats slabs'.

=item C<items>

The stats returned by a 'stats items'.

=back

=item C<disconnect_all>

$memd->disconnect_all;

Closes all cached sockets to all memcached servers.  You must do this
if your program forks and the parent has used this module at all.
Otherwise the children will try to use cached sockets and they'll fight
(as children do) and garble the client/server protocol.

=item C<flush_all>

$memd->flush_all;

Runs the memcached "flush_all" command on all configured hosts,
emptying all their caches.  (or rather, invalidating all items
in the caches in an O(1) operation...)  Running stats will still
show the item existing, they're just be non-existent and lazily
destroyed next time you try to detch any of them.

=back

=head1 BUGS

When a server goes down, this module does detect it, and re-hashes the
request to the remaining servers, but the way it does it isn't very
clean.  The result may be that it gives up during its rehashing and
refuses to get/set something it could've, had it been done right.

=head1 COPYRIGHT

This module is Copyright (c) 2003 Brad Fitzpatrick.
All rights reserved.

You may distribute under the terms of either the GNU General Public
License or the Artistic License, as specified in the Perl README file.

=head1 WARRANTY

This is free software. IT COMES WITHOUT WARRANTY OF ANY KIND.

=head1 FAQ

See the memcached website:
   http://www.danga.com/memcached/

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com>

Anatoly Vorobey <mellon@pobox.com>

Brad Whitaker <whitaker@danga.com>

Jamie McCarthy <jamie@mccarthy.vg>
