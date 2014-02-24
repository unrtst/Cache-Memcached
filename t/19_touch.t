#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
unless ($msock) {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => "Cache::Memcached::t/$$/" . (time() % 100) . "/",
});

my $memcached_version;

eval {
    require version;
    die "version too old" unless $version::VERSION >= 0.77;
    $memcached_version =
        version->parse(
            $memd->stats('misc')->{hosts}->{$testaddr}->{misc}->{version}
        );
    diag("Server version: $memcached_version") if $memcached_version;
};


unless ($memcached_version) {
    plan skip_all => "Could not parse server version; version.pm 0.77 required\n";
    exit 0;
}
unless ($memcached_version && $memcached_version >= v1.4.8) {
    plan skip_all => "Only using touch/gat/gatq on memcached >= 1.4.8, you have $memcached_version\n";
}

plan tests => 7;


ok($memd->set("key1", "val1", 3), "set key1 to val1 (3 sec expiration)");
is($memd->get("key1"), "val1",    "get key1 is val1");
sleep 8;
ok(! $memd->get("key1"),          "get key1 no expired");

ok($memd->set("key1", "val2", 3), "set key1 to val2 (3 sec expiration)");
ok($memd->touch("key1", 30),      "touch key1 (30 sec expiration)");
is($memd->get("key1"), "val2",    "get key1 is val2");
sleep 8;
ok(! $memd->get("key1"),          "get key1 not expired yet");

