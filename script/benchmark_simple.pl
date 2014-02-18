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

use constant default_iteration_count => 1_000;
use constant key_count => 100;
use constant NOWAIT => 1;
use constant NOREPLY => 1;

my $value = 'x' x 40;
my $sm_val = "xxx";
my $lg_val = "x" x (1024 * 512); # ~ 512kb
my $sm_ref = { a => 1 };
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
        compress_eanble => 0,
    }),
    'compress'      => Cache::Memcached->new({
        servers => \@addrs,
        select_timeout => 2,
        compress_eanble => 1,
        compress_threshold => 500, # bytes
    }),
);
# make sure compress_enable is set correctly (version <= 1.30 did not accept it to new())
$instances{nocompress}->enable_compress(0);
$instances{compress}->enable_compress(1);


my %benchmarks;
foreach my $instance (keys %instances) {
    my $memd = $instances{$instance};
    $benchmarks{'small_val_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $sm_val);
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
    $benchmarks{'large_struct_'.$instance} = sub {
        my $k = "snc".int(rand($max_keys));
        $memd->set($k, $lg_ref);
        my $g = $memd->get($k);
    };
}

timethese($count, \%benchmarks);

