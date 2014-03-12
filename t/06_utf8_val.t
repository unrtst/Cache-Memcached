#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 23;
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
my $val1 = "Ïâ";
my $val2 = "Ïâb";
my $val3 = "Ïâc";

TODO: {
    local $TODO = "utf8 values do not appear to work at this time";

    ok($memd->set("key1", $val1), "set key1 as val1");

    is($memd->get("key1"), $val1, "get key1 is val1");
    ok(! $memd->add("key1", "replace-$val1"), "add key1 properly failed");
    ok($memd->add("key2", $val2), "add key2 as val2");
    is($memd->get("key2"), $val2, "get key2 is val2");

    ok($memd->replace("key2", "replace-$val2"), "replace key2 as replace-val2");
    is($memd->get("key2"), "replace-$val2", "get key2 is replace-val2");
    ok(! $memd->replace("key-noexist", $val2), "replace key-noexist properly failed");

    ok($memd->delete("key1"), "delete key1");
    ok(! $memd->get("key1"), "get key1 properly failed");

    SKIP: {
      skip "Could not parse server version; version.pm 0.77 required", 8
          unless $memcached_version;
      skip "Only using prepend/append on memcached >= 1.2.4, you have $memcached_version", 8
          unless $memcached_version && $memcached_version >= v1.2.4;

      ok(! $memd->append("key-noexistkey1", $val3), "append key-noexist properly failed");
      ok(! $memd->prepend("key-noexistkey1", $val3), "prepend key-noexist properly failed");
      ok($memd->set("key3", $val3), "set key3 to val3");
      ok($memd->append("key3", "-end"), "appended -end to key3");
      ok($memd->get("key3", $val3."-end"), "key3 is \$val3-end");
      ok($memd->prepend("key3", "start-"), "prepended start- to key3");
      ok($memd->get("key3", "start-".$val3."-end"), "key3 is start-\$val3-end");

      # clean up after ourselves
      ok($memd->delete("key3"), "delete key3");
    }

    #### make sure get_multi works too
    ok($memd->set("key1", $val1), "set key1 as val1");
    ok($memd->set("key2", $val2), "set key2 as val2");
    is_deeply(
        $memd->get_multi("key1", "key2"),
        {
            "key1" => $val1,
            "key2" => $val2,
        }, "get_multi key1,key2 is val1,val2"
    );

    # clean up after ourselves
    ok($memd->delete("key1"), "delete key1"); # already deleted
    ok($memd->delete("key2"), "delete key2");
}
