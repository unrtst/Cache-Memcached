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
    plan tests => 163;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    enable_key_hashing  => 1,
    # fake in a key hashing method that lets us easily debug it
    key_hash_method => sub { substr( $_[0], -1)."abcd" },
});

#### basic operation
ok($memd->set("key1", "val1"), "set key1 as val1");

is($memd->get("key1"), "val1", "get key1 is val1");
ok(! $memd->add("key1", "val-replace"), "add key1 properly failed");
ok($memd->add("key2", "val2"), "add key2 as val2");
is($memd->get("key2"), "val2", "get key2 is val2");

ok($memd->replace("key2", "val-replace"), "replace key2 as val-replace");
is($memd->get("key2"), "val-replace", "get key2 is val-replace");
ok(! $memd->replace("key-noexist", "bogus"), "replace key-noexist properly failed");

ok($memd->delete("key1"), "delete key1");
ok(! $memd->get("key1"), "get key1 properly failed");


# add key1 back in using hashed key
ok($memd->set("key1", "val1"), "set key1 as val1");
ok($memd->set("key3", "val3"), "set key3 as val3");

#### make sure get_multi works too
is_deeply(
    $memd->get_multi("key1", "key3"),
    {
        "key1" => "val1",
        "key3" => "val3",
    }, "get_multi key1,key3 is val1,val3"
);

# make a new instance that lets us use the raw keys to confirm whats happening
my $memd2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    enable_key_hashing  => 0,
});

# confirm it got hashed in the server using our custom key_hash_method
is($memd2->get("1abcd"), "val1", "introspective get 1abcd (hashed key1) is val1");
is($memd2->get("3abcd"), "val3", "introspective get 3abcd (hashed key3) is val3");

# same with get_multi
is_deeply(
    $memd2->get_multi("1abcd", "3abcd"),
    {
        "1abcd" => "val1",
        "3abcd" => "val3",
    }, "introspective get_multi 1abcd,3abcd (key1,key3) is val1,val3"
);

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
ok($memd->delete("key2"), "delete key2");
ok($memd->delete("key3"), "delete key3");



# try some other actual digest modules
my %other_modules = (
    'Digest::SHA1::sha1_base64'             => 'Digest::SHA1',
    'Digest::SHA::PurePerl::sha1_base64'    => 'Digest::SHA::PurePerl',
    'Digest::SHA::sha1_base64'              => 'Digest::SHA',
    'Digest::SHA::sha256_base64'            => 'Digest::SHA',
    'Digest::SHA::sha512_base64'            => 'Digest::SHA',
    'Digest::MD5::md5_base64'               => 'Digest::MD5',
    'Digest::MD5::md5_hex'                  => 'Digest::MD5',
    'Digest::Perl::MD5::md5_base64'         => 'Digest::Perl::MD5',
    'Digest::MD4::md4_base64'               => 'Digest::MD4',
);

while (my ($method, $lib) = each %other_modules) {
    SKIP: {
        LOADLIB:
        eval "require $lib";
        if ($@) {
            skip "$lib not installed", 16;
        }

        # new namespace for each test, so "add" tests don't stomp on each other
        my $mod_namespace = "$namespace/$method/";
        my $memd = Cache::Memcached->new({
            servers   => [ $testaddr ],
            namespace => $mod_namespace,
            enable_key_hashing  => 1,
            # fake in a key hashing method that lets us easily debug it
            key_hash_method => sub { no strict 'refs'; &{$method}( $_[0] ) },
        });

        ok($memd->set("key1", "val1"), "[$method] set key1 as val1");

        is($memd->get("key1"), "val1", "[$method] get key1 is val1");
        ok(! $memd->add("key1", "val-replace"), "[$method] add key1 properly failed");
        ok($memd->add("key2", "val2"), "[$method] add key2 as val2");
        is($memd->get("key2"), "val2", "[$method] get key2 is val2");

        ok($memd->replace("key2", "val-replace"), "[$method] replace key2 as val-replace");
        is($memd->get("key2"), "val-replace", "[$method] get key2 is val-replace");
        ok(! $memd->replace("key-noexist", "bogus"), "[$method] replace key-noexist properly failed");

        ok($memd->delete("key1"), "[$method] delete key1");
        ok(! $memd->get("key1"), "[$method] get key1 properly failed");


        # add key1 back in using hashed key
        ok($memd->set("key1", "val1"), "[$method] set key1 as val1");
        ok($memd->set("key3", "val3"), "[$method] set key3 as val3");

        #### make sure get_multi works too
        is_deeply(
            $memd->get_multi("key1", "key3"),
            {
                "key1" => "val1",
                "key3" => "val3",
            }, "[$method] get_multi key1,key3 is val1,val3"
        );

        # clean up after ourselves
        ok($memd->delete("key1"), "[$method] delete key1");
        ok($memd->delete("key2"), "[$method] delete key2");
        ok($memd->delete("key3"), "[$method] delete key3");
    };
}

