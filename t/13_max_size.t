#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 8;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 0,
    # set compress_threshold high so we make sure it isn't triggered
    compress_threshold => 1024*2048, # bytes
    max_size  => 512, # bytes
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd->enable_compress(0);


# make sure small values work
ok($memd->set("key1", "val1"), "set key1 to val1");
is($memd->get("key1"), "val1", "get key1 is val1");

# large value should get rejected
ok( ! $memd->set("key2", ("x" x (1024*512))), "set key2 to a large value");
ok( ! $memd->get("key2"), "get key2 properly failed");

# see if we can modify that behavior
$memd->set_max_size(0);
ok($memd->set("key3", ("x" x (1024*512))), "set key3 to a large value");
is($memd->get("key3"), ("x" x (1024*512)), "get key3 is correct");

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
#ok($memd->delete("key2"), "delete key2"); # key2 should never get set
ok($memd->delete("key3"), "delete key3");
