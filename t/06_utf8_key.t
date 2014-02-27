#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 35;
} else {
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


use utf8;
my $key1 = "Ïâ";
my $key2 = "Ïâb";
my $key3 = "Ïâc";

ok($memd->set($key1, "val1"), "set key1 as val1");

is($memd->get($key1), "val1", "get key1 is val1");
ok(! $memd->add($key1, "val-replace"), "add key1 properly failed");
ok($memd->add($key2, "val2"), "add key2 as val2");
is($memd->get($key2), "val2", "get key2 is val2");

ok($memd->replace($key2, "val-replace"), "replace key2 as val-replace");
is($memd->get($key2), "val-replace", "get key2 is val-replace");
ok(! $memd->replace("key-noexist", "bogus"), "replace key-noexist properly failed");

ok($memd->delete($key1), "delete key1");
ok(! $memd->get($key1), "get key1 properly failed");

SKIP: {
  skip "Could not parse server version; version.pm 0.77 required", 8
      unless $memcached_version;
  skip "Only using prepend/append on memcached >= 1.2.4, you have $memcached_version", 8
      unless $memcached_version && $memcached_version >= v1.2.4;

  ok(! $memd->append("key-noexist$key1", "bogus"), "append key-noexist properly failed");
  ok(! $memd->prepend("key-noexist$key1", "bogus"), "prepend key-noexist properly failed");
  ok($memd->set($key3, "base"), "set key3 to base");
  ok($memd->append($key3, "-end"), "appended -end to key3");
  ok($memd->get($key3, "base-end"), "key3 is base-end");
  ok($memd->prepend($key3, "start-"), "prepended start- to key3");
  ok($memd->get($key3, "start-base-end"), "key3 is start-base-end");

  # clean up after ourselves
  ok($memd->delete($key3), "delete key3");
}

#### make sure get_multi works too
ok($memd->set($key1, "val1"), "set key1 as val1");
ok($memd->set($key2, "val2"), "set key2 as val2");
is_deeply(
    $memd->get_multi($key1, $key2),
    {
        "$key1" => "val1",
        "$key2" => "val2",
    }, "get_multi key1,key2 is val1,val2"
);

#### test incr/decr
ok($memd->set($key1, 0), "replace with numeric");
ok($memd->incr($key1), 'Incr');
is($memd->get($key1), 1, 'Fetch');
ok($memd->incr($key1, 5), 'Incr');
ok((not $memd->incr("$key3.no-such-key", 5)), 'Incr $key3.no_such_key');

# This passes in Cache::Memcached::Fast, but not in Cache::Memcached
#ok((defined $memd->incr("$key3.no-such-key", 5)),
#   'Incr $key3.no_such_key returns defined value');

is($memd->get($key1), 6, 'Fetch');
ok($memd->decr($key1), 'Decr');
is($memd->get($key1), 5, 'Fetch');
ok($memd->decr($key1, 2), 'Decr');
is($memd->get($key1), 3, 'Fetch');
ok($memd->decr($key1, 100) == 0, 'Decr below zero');

# This passes in Cache::Memcached::Fast, but not in Cache::Memcached
#ok($memd->decr($key1, 100), 'Decr below zero returns true value');

is($memd->get($key1), 0, 'Fetch');

# clean up after ourselves
ok($memd->delete($key1), "delete key1"); # already deleted
ok($memd->delete($key2), "delete key2");
