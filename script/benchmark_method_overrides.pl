#!/usr/bin/perl
#
# Copyright (C) 2007-2008 Tomash Brechko.  All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself, either Perl version 5.8.8
# or, at your option, any later version of Perl 5 you may have
# available.
#

use strict;
use Benchmark;
use Cache::Memcached;
use Compress::LZ4;
use JSON::XS;

#use constant default_iteration_count => 1_000;
use constant default_iteration_count => -2; # -2 has it run for 2 seconds each test
use constant key_count => 100;
use constant NOWAIT => 1;
use constant NOREPLY => 1;

my $value = 'x' x 40;
my $sm_val = "xxx";
my $md_val = "x" x (1024); # ~ 1kb
my $lg_val = "x" x (1024 * 512); # ~ 512kb
my $sm_ref = { a => 1 };
my $md_ref = { map { ('x' x 14).$_ => $_ } (1..64) }; # ~ 1.5kb
my $lg_ref = { map { ('x' x 1024).$_ => $_ } (1..512) }; # ~ 518kb


use FindBin;

@ARGV >= 1
    or die("Usage: $FindBin::Script HOST:PORT... [COUNT]\n"
           . "\n"
           . "HOST:PORT...  - list of memcached server addresses.\n"
           . "COUNT         - number of iterations (default "
                              . default_iteration_count . ").\n"
           . "                (each iteration will process "
                              . key_count . " keys).\n");

my $count = ($ARGV[$#ARGV] =~ /^\d+$/ ? pop @ARGV : default_iteration_count);
my $max_keys = $count * key_count / 2;

my @addrs = @ARGV;

my %instances = (
    'nocompress'    => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 0,
    }),
    'compress'      => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
    }),
    'lz4'           => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
        compress_methods => [
            sub { ${$_[1]} = Compress::LZ4::compress( $_[0] )   },
            sub { ${$_[1]} = Compress::LZ4::decompress( $_[0] ) },
        ],
    }),
    'jsonxs'        => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 0,
        compress_threshold => 500, # bytes
        serialize_methods => [
            sub { JSON::XS::encode_json($_[0]) },
            sub { JSON::XS::decode_json($_[0]) },
        ],
    }),
    'lz4jsonxs'     => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
        compress_methods => [
            sub { ${$_[1]} = Compress::LZ4::compress( $_[0] )   },
            sub { ${$_[1]} = Compress::LZ4::decompress( $_[0] ) },
        ],
        serialize_methods => [
            sub { JSON::XS::encode_json($_[0]) },
            sub { JSON::XS::decode_json($_[0]) },
        ],
    }),

    ## ... same as above set, but with hashed keys enabled
    'nocompress_HK' => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 0,
        enable_key_hashing => 1,
    }),
    'compress_HK'   => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
        enable_key_hashing => 1,
    }),
    'lz4_HK'        => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
        compress_methods => [
            sub { ${$_[1]} = Compress::LZ4::compress( $_[0] )   },
            sub { ${$_[1]} = Compress::LZ4::decompress( $_[0] ) },
        ],
        enable_key_hashing => 1,
    }),
    'jsonxs_HK'     => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 0,
        compress_threshold => 500, # bytes
        serialize_methods => [
            sub { JSON::XS::encode_json($_[0]) },
            sub { JSON::XS::decode_json($_[0]) },
        ],
        enable_key_hashing => 1,
    }),
    'lz4jsonxs_HK'  => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_enable => 1,
        compress_threshold => 500, # bytes
        compress_methods => [
            sub { ${$_[1]} = Compress::LZ4::compress( $_[0] )   },
            sub { ${$_[1]} = Compress::LZ4::decompress( $_[0] ) },
        ],
        serialize_methods => [
            sub { JSON::XS::encode_json($_[0]) },
            sub { JSON::XS::decode_json($_[0]) },
        ],
        enable_key_hashing => 1,
    }),
);
# make sure compress_enable is set correctly (version <= 1.30 did not accept it to new())
$instances{nocompress}->enable_compress(0);
$instances{compress}->enable_compress(1);
$instances{jsonxs}->enable_compress(0);
$instances{lz4}->enable_compress(1);
$instances{lz4jsonxs}->enable_compress(1);
$instances{nocompress_HK}->enable_compress(0);
$instances{compress_HK}->enable_compress(1);
$instances{jsonxs_HK}->enable_compress(0);
$instances{lz4_HK}->enable_compress(1);
$instances{lz4jsonxs_HK}->enable_compress(1);


my %benchmarks;
foreach my $instance (keys %instances) {
    my $memd = $instances{$instance};
    $benchmarks{'small_val_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $sm_val);
        my $g = $memd->get($k);
    };
    $benchmarks{'medium_val_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $md_val);
        my $g = $memd->get($k);
    };
    $benchmarks{'large_val_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $lg_val);
        my $g = $memd->get($k);
    };
    $benchmarks{'small_struct_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $sm_ref);
        my $g = $memd->get($k);
    };
    $benchmarks{'medium_struct_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $md_ref);
        my $g = $memd->get($k);
    };
    $benchmarks{'large_struct_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $lg_ref);
        my $g = $memd->get($k);
    };
}

timethese($count, \%benchmarks);

