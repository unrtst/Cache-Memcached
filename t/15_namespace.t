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
    plan tests => 42;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

close $msock;

my $namespace_1 = "Cache::Memcached::t/$$/" . (time() % 100) . "1/";
my $namespace_2 = "Cache::Memcached::t/$$/" . (time() % 100) . "2/";

my $mem1 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace_1,
});

my $mem2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    # NOTE: should test with no namespace, but that could risk production data
    namespace => $namespace_2,
});

isa_ok($mem1, 'Cache::Memcached');

my $memcached_version;

eval {
    require version;
    die "version too old" unless $version::VERSION >= 0.77;
    $memcached_version =
        version->parse(
            $mem1->stats('misc')->{hosts}->{$testaddr}->{misc}->{version}
        );
    diag("Server version: $memcached_version") if $memcached_version;
};

ok($mem1->set("key1", "val1"), "[mem1] set key1 as val1");
is($mem1->get("key1"), "val1", "[mem1] get key1 is val1");

ok( ! $mem2->get("key1"),      "[mem2] get key1 properly failed");
ok($mem2->set("key1", "valA"), "[mem2] set key1 as valA");
is($mem2->get("key1"), "valA", "[mem2] get key1 is valA");

is($mem1->get("key1"), "val1", "[mem1] get key1 is still val1");

ok($mem1->set("key2", "val2"), "[mem1] set key2 as val2");
is($mem1->get("key2"), "val2", "[mem1] get key2 is val2");
ok($mem2->add("key2", "valB"), "[mem2] add key2 as valB");
ok(! $mem1->add("key2", "val-replace"), "[mem1] add key2 properly failed");
is($mem2->get("key2"), "valB", "[mem2] get key2 is valB");

ok($mem1->replace("key2", "val-replace"), "[mem1] replace key2 as val-replace");
is($mem1->get("key2"), "val-replace", "[mem1] get key2 is val-replace");
is($mem2->get("key2"), "valB", "[mem2] get key2 is still valB");
ok($mem2->replace("key2", "valB-replace"), "[mem2] replace key2 as valB-replace");
is($mem2->get("key2"), "valB-replace", "[mem2] get key2 is valB-replace");
is($mem1->get("key2"), "val-replace", "[mem1] get key2 is still val-replace");

ok($mem1->delete("key1"), "[mem1] delete key1");
ok(! $mem1->get("key1"), "[mem1] get key1 properly failed");
is($mem2->get("key1"), "valA", "[mem2] get key1 is still valA");
ok($mem2->delete("key1"), "[mem2] delete key1");
ok(! $mem2->get("key1"), "[mem2] get key1 properly failed");



SKIP: {
  skip "Could not parse server version; version.pm 0.77 required", 17
      unless $memcached_version;
  skip "Only using prepend/append on memcached >= 1.2.4, you have $memcached_version", 17
      unless $memcached_version && $memcached_version >= v1.2.4;

  ok(! $mem1->append("key-noexist", "bogus"), "[mem1] append key-noexist properly failed");
  ok(! $mem1->prepend("key-noexist", "bogus"), "[mem1] prepend key-noexist properly failed");
  ok($mem1->set("key3", "base"), "[mem1] set key3 to base");
  ok($mem1->append("key3", "-end"), "[mem1] appended -end to key3");
  ok($mem1->get("key3", "base-end"), "[mem1] key3 is base-end");

  ok(! $mem2->append("key3", "bogus"), "[mem2] append key3 properly failed");
  ok(! $mem2->prepend("key3", "bogus"), "[mem2] prepend key3 properly failed");
  ok($mem2->set("key3", "baseB"), "[mem2] set key3 to baseB");
  ok($mem2->append("key3", "-end"), "[mem2] appended -end to key3");
  ok($mem2->get("key3", "baseB-end"), "[mem2] key3 is baseB-end");

  ok($mem1->prepend("key3", "start-"), "[mem1] prepended start- to key3");
  ok($mem1->get("key3", "start-base-end"), "[mem1] key3 is start-base-end");

  ok($mem2->prepend("key3", "start-"), "[mem2] prepended start- to key3");
  ok($mem2->get("key3", "start-baseB-end"), "[mem2] key3 is start-baseB-end");

  ok($mem1->get("key3", "start-base-end"), "[mem1] key3 is still start-base-end");

  # clean up after ourselves
  ok($mem1->delete("key3"), "[mem1] delete key3");
  ok($mem2->delete("key3"), "[mem2] delete key3");
}


# clean up after ourselves
#ok($mem1->delete("key1"), "[mem1] delete key1"); # already deleted
ok($mem1->delete("key2"), "[mem1] delete key2");

#ok($mem2->delete("key1"), "[mem2] delete key1"); # already deleted
ok($mem2->delete("key2"), "[mem2] delete key2");
