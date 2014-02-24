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
unless ($memcached_version && $memcached_version >= v1.2.4) {
    plan skip_all => "Only using cas/gets/gets_multi on memcached >= 1.2.4, you have $memcached_version\n";
}

plan tests => 17;




# XXX: tests borrowed and tweaked from Cache::Memcached::Fast t/commands.t
my @keys = ("key1", "key2");
my @extra_keys = @keys;
for (1..100) {
    splice(@extra_keys, int(rand(@extra_keys + 1)), 0, "no_such_key-$_");
}

foreach my $key (@keys) {
    ok($memd->set($key, $key), "set $key as $key");
}

my $key = "key3";
ok($memd->set($key, "prepend-value-append"), "set $key as prepend-value-append");


my $res;
$res = $memd->gets($key);
ok($res, "Gets");
isa_ok($res, 'ARRAY');
is(scalar @$res, 2, 'Gets result is an array of two elements');

ok($res->[0], 'CAS opaque defined');
is($res->[1], 'prepend-value-append', 'Match value');
$res->[1] = 'new value';
ok($memd->cas($key, @$res), 'First update success');
ok(! $memd->cas($key, @$res), 'Second update failure');
is($memd->get($key), 'new value', 'Fetch');

$res = $memd->gets_multi(@extra_keys);
isa_ok($res, 'HASH');
is(scalar keys %$res, scalar @keys, 'Number of entries in result');
my $count = 0;
foreach my $k (@keys) {
    ++$count if ref($res->{$k}) eq 'ARRAY';
    ++$count if @{$res->{$k}} == 2;
    ++$count if defined $res->{$k}->[0];
    ++$count if $res->{$k}->[1] eq $k;
}
is($count, scalar @keys * 4);


# clean up after ourselves
foreach my $key (@keys, "key3") {
    ok($memd->delete($key), "delete $key");
}
