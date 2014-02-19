#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 12;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 1,
    # set compress_threshold low so we make sure it is triggered
    compress_threshold => 500, # bytes
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd->enable_compress(1);

my $mem2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 0,
    # fake in decompress method so it does not decompress
    compress_methods => [
        sub { ${$_[1]} = ${$_[0]} },
        sub { ${$_[1]} = ${$_[0]} },

    ],
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$mem2->enable_compress(0);

# make a big random string
my $rand;
$rand .= chr(rand(255)) for 1 .. (1024*256);


# make sure easily compressable stuff compresses
ok($memd->set("key1", ("x" x (1024*512))), "set key1 to a large value");
#is($memd->get("key1"), ("x" x (1024*512)), "get key1 is correct");
ok($memd->get("key1") eq ("x" x (1024*512)), "get key1 is correct");
cmp_ok( length($mem2->get("key1")), '<', (1024*512), "confirm key1 value got compressed");

# make sure random data does not compress
ok($memd->set("key2", $rand), "set key2 to large random value");
#is($memd->get("key2"), $rand, "get key2 is correct");
ok($memd->get("key2") eq $rand, "get key2 is correct");
cmp_ok( length($mem2->get("key2")), '==', (1024*256), "confirm key2 value was not compressed");


# set a high compression ratio so the easily compressed doesn't get compressed either
# 0 * length(orig_val) == 0... and compressed size can't be smaller than that!
$memd->set_compress_ratio(0);
ok($memd->set("key3", ("x" x (1024*512))), "set key3 to a large value");
#is($memd->get("key3"), ("x" x (1024*512)), "get key3 is correct");
ok($memd->get("key3") eq ("x" x (1024*512)), "get key3 is correct");
cmp_ok( length($mem2->get("key3")), '==', (1024*512), "confirm key3 value was not compressed");


# clean up after ourselves
ok($memd->delete("key1"), "delete key1"); 
ok($memd->delete("key2"), "delete key2");
ok($memd->delete("key3"), "delete key3");

