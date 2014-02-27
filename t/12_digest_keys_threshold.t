#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

unless ($^V) {
    plan skip_all => "This test requires perl 5.6.0+\n";
    exit 0;
}

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 51;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    digest_keys_enable  => 1,
    # fake in a key hashing method that lets us easily debug it
    digest_keys_method => sub { my $t = shift; $t =~ s/./x/g; $t },
    # keys longer than (or equal to) length(namespace) + 10 get digest
    digest_keys_threshold => length($namespace) + 10,
});

# make a new instance that lets us use the raw keys to confirm whats happening
my $memd2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    digest_keys_enable  => 0,
});


#### set some various keys and make sure we can still get them
#### - using the length as the difference between keys for our debug digets_keys_method
foreach my $i (4 .. 20) {
    my $key = substr($i,0,1) x $i;
    ok($memd->set($key, "val$i"), "set $key as val$i");
}
# get them using digest
foreach my $i (4 .. 20) {
    my $key = substr($i,0,1) x $i;
    is($memd->get($key), "val$i", "get $key as val$i");
}

# confirm they went in with expected raw values
foreach my $i (4 .. 20) {
    my $digest_key = substr($i,0,1) x $i;
    my $key = ($i >= 10)
            ? 'x' x $i
            : $digest_key;
    is($memd2->get($key), "val$i", "(introspective) get $digest_key with $key as val$i");
}


