#!/usr/bin/perl

# See Cache::Memcached -> get_sock : IE:
#XXX: performance note regarding digest_keys_method...
#     When digest_keys_enabled, digest_keys_method is called twice for most operations:
#       1. in the method (ex. delete()) to get the key to send to memcached server
#       2. in the call to get_sock to figure out what server to use
#     I benchmarked using a method to cache that result in an instance variable.
#     It performed worse than simply calling the digest_keys_method twice (assuming
#     the use of Digest::MD5::md5_base64).
#     In summary, leave it at two separate calls until you bench the caching.
#       (see scripts/benchmark_digest_keys_caching.pl)

# This benchmark tests that.

# My results were:
#Benchmark: running mC, mR, mdC, mdR for at least 4 CPU seconds...
#        mC:  4 wallclock secs ( 4.01 usr +  0.00 sys =  4.01 CPU) @ 279351.12/s (n=1120198)
#        mR:  5 wallclock secs ( 4.16 usr +  0.00 sys =  4.16 CPU) @ 503435.82/s (n=2094293)
#       mdC:  4 wallclock secs ( 4.31 usr +  0.00 sys =  4.31 CPU) @ 212877.03/s (n=917500)
#       mdR:  3 wallclock secs ( 4.20 usr +  0.00 sys =  4.20 CPU) @ 246197.62/s (n=1034030)


##################################################
##################################################
# TestCached : mock object doing the double calls with a cached digest_keys_method
package TestCached;
use strict;
use Digest::MD5;
sub new
{
    my $proto = shift;
    my $class = ref $proto || $proto;

    my $self = {};
    $self->{'digest_keys_enable'} = 1;
    $self->{'digest_keys_method'} = sub {
        Digest::MD5::md5_hex($_)
    };
    bless($self, $class);

    return $self;
}

sub get_sock {
    my $self = $_[0];
    my $key  = $_[1];
    my $real_key = $self->_digest_key($key);
    return $real_key;
}

sub get {
    my $self = $_[0];
    my $key = $_[1];

    my $real_key = $self->_digest_key( $key );

    my $sock = $self->get_sock($key);

    return $real_key;
}

sub _digest_key {
    #my Cache::Memcached $self = shift;
    my $self = shift;
    my $key = ref $_[0] ? $_[0]->[1] : $_[0];
    return $key unless $self->{'digest_keys_enable'};
    return $self->{'_dkcache'}{$key} if defined $self->{'_dkcache'}{$key};
    return $self->{'_dkcache'}{$key} = $self->{'digest_keys_method'}->( $key );
}

##################################################
##################################################
# TestRaw: mock object doing the double calls without a caching wrapper
package TestRaw;
use strict;
use Digest::MD5;
sub new
{
    my $proto = shift;
    my $class = ref $proto || $proto;

    my $self = {};
    $self->{'digest_keys_enable'} = 1;
    $self->{'digest_keys_method'} = sub {
        Digest::MD5::md5_hex($_)
    };
    bless($self, $class);

    return $self;
}

sub get_sock {
    my $self = $_[0];
    my $key  = $_[1];
    my $real_key = ref $key ? $key->[1] : $key;
    $real_key = $self->{'digest_keys_method'}->( $real_key ) if $self->{'digest_keys_enable'};
    return $real_key;
}

sub get {
    my $self = $_[0];
    my $key = $_[1];

    my $real_key = ref $key ? $key->[1] : $key;
    $real_key = $self->{'digest_keys_method'}->( $real_key ) if $self->{'digest_keys_enable'};

    my $sock = $self->get_sock($key);

    return $real_key;
}

##################################################
##################################################
package main;

use strict;
use Benchmark;

my $count = -4;

my @keys = map { "key$_" } 1..40;
my $key_count = @keys;

my $mem_cached_digest = TestCached->new();
my $mem_raw_digest    = TestRaw->new();
my $mem_cached        = TestCached->new();
$mem_cached->{'digest_keys_enable'} = 0;
my $mem_raw           = TestRaw->new();
$mem_raw->{'digest_keys_enable'} = 0;

timethese($count, {
    'mdC'   => sub {
        $mem_cached_digest->get( @keys[ int(rand($key_count)) ] );
    },
    'mdR'    => sub {
        $mem_raw_digest->get( @keys[ int(rand($key_count)) ] );
    },
    'mC'    => sub {
        $mem_cached->get( @keys[ int(rand($key_count)) ] );
    },
    'mR'     => sub {
        $mem_raw->get( @keys[ int(rand($key_count)) ] );
    },
});



