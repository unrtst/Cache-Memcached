#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

BEGIN {
    require "t/test_structs.pl";
}

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 6;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => "Cache::Memcached::t/$$/" . (time() % 100) . "/",
});

ok($memd->set("key1", get_small_struct()),        "set key1 to small struct");
is_deeply($memd->get("key1"), get_small_struct(), "get key1 is small struct");

ok($memd->set("key2", get_jvm_struct()),        "set key1 to jvm struct");
is_deeply($memd->get("key2"), get_jvm_struct(), "get key2 is jvm struct");

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
ok($memd->delete("key2"), "delete key2");
