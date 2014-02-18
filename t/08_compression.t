#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 6;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 1,
    # set compress_threshold small so we don't need big values
    compress_threshold => 500, # bytes
    # COMPRESS_SAVINGS stuck at 20%
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd->enable_compress(1);


# stick in a value that is highly compressable
ok($memd->set("key1", "".("A" x (1024*512)) ), "set key1 to 512k of repeated 'A'");
is($memd->get("key1"), "".("A" x (1024*512)),  "get key1 is same string");

# make a big random string
my $rand;
$rand .= chr(rand(255)) for 1 .. (1024*256);

ok($memd->set("key2", $rand), "set key2 to 512k of repeated 'A'");
is($memd->get("key2"), $rand, "get key2 is same string");

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
ok($memd->delete("key2"), "delete key2");

