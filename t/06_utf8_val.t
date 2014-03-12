#!/usr/bin/env perl -w

# SEE ALSO: https://rt.cpan.org/Public/Bug/Display.html?id=28095
# The patch there did not work consistently (ex. older memcached servers).
# Tests from it are included here in addition tests written before I saw that RT.

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;
use Encode qw(is_utf8);

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


# inline utf8 data
use utf8;
my $val1 = "Ïâ";
my $val2 = "Ïâb";
my $val3 = "Ïâc";
no utf8;


########################
# tests from RT 28095
# encoded utf8 data
my $u_str = "\x{99f1}\x{99dd}";
my $a_str = "ASCII";
my $b_str = "\xe9\xa7\xb1\xe9\xa7\x9d";

ok(is_utf8($u_str), "check utf8 capability");
ok(!is_utf8($a_str), "check utf8 capability");
ok(!is_utf8($b_str), "check utf8 capability");
ok($memd->set("u", $u_str), "set utf8");
ok($memd->set("a", $a_str), "set ascii");
ok($memd->set("b", $b_str), "set binary");
is($memd->get("u"), $u_str, "get utf8");
is($memd->get("a"), $a_str, "get ascii");
is($memd->get("b"), $b_str, "get binary");
ok(is_utf8($memd->get("u")), "check flag of getted utf8 value");
ok(!is_utf8($memd->get("a")), "check flag of getted ascii value");
ok(!is_utf8($memd->get("b")), "check flag of getted binary value");


########################
# tests added in addition to RT 28095
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
