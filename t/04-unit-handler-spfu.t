#!/usr/bin/env perl

use strict;
use warnings;
use lib 't';

use Mail::Milter::Authentication::Tester::HandlerTester;
use Mail::Milter::Authentication::Constants qw{ :all };
use Test::Exception;
use Test::More;

my $basedir = q{};

mkdir 't/tmp';
open( STDERR, '>>', $basedir . 't/tmp/misc.err' ) || die "Cannot open errlog [$!]";
open( STDOUT, '>>', $basedir . 't/tmp/misc.err' ) || die "Cannot open errlog [$!]";

my $tester = Mail::Milter::Authentication::Tester::HandlerTester->new({
    'protocol' => 'smtp',
    'prefix'   => $basedir . 't/config/handler/etc',
    'zonefile' => $basedir . 't/zonefile',
    'handler_config' => {
        'SPF' => {},
        'DMARC' => {},
        'DKIM' => {},
    },
});
$tester->snapshot( 'new' );

my @headers = (
    'X-Received-Authentication-Results: mx.microsoft.com 1; spf=fail (sender ip is 23.26.253.8) smtp.rcpttodomain=gmail.com smtp.mailfrom=spfuvictim.com; dmarc=fail (p=reject sp=reject pct=100) action=oreject header.from=foobar.spfuvictim.com; dkim=none (message not signed); arc=none',
    'Authentication-Results: mx.microsoft.com 1; spf=fail (sender ip is 23.26.253.8) smtp.rcpttodomain=gmail.com smtp.mailfrom=spfuvictim.com; dmarc=fail (p=reject sp=reject pct=100) action=oreject header.from=foobar.spfuvictim.com; dkim=none (message not signed); arc=none',
    'ARC-Authentication-Results: i=1; mx.microsoft.com 1; spf=fail (sender ip is 23.26.253.8) smtp.rcpttodomain=gmail.com smtp.mailfrom=spfuvictim.com; dmarc=fail (p=reject sp=reject pct=100) action=oreject header.from=foobar.spfuvictim.com; dkim=none (message not signed); arc=none',
    'X-MS-Exchange-Authentication-Results: spf=fail (sender IP is 23.26.253.8) smtp.mailfrom=spfuvictim.com; dkim=none (message not signed) header.d=none;dmarc=fail action=oreject header.from=foobar.spfuvictim.com;',
    'Received-SPF: Fail (protection.outlook.com: domain of spfuvictim.com does not designate 23.26.253.8 as permitted sender) receiver=protection.outlook.com; client-ip=23.26.253.8; helo=fa83.windbound.org.uk;',
);

subtest 'spfu detection all headers' => sub {

    $tester->switch( 'new' );
    $tester->run({
        'connect_ip' => '1.2.3.4',
        'connect_name' => 'mx.example.com',
        'helo' => 'mx.example.com',
        'mailfrom' => 'test@foobar.spfuvictim.com',
        'rcptto' => [ 'test@example.net' ],
        'body' => join( "\n", @headers, 
'From: Test <localpart@foobar.spfuvictim.com>
Subject: Test
To: email_address@example.com
Date: Tue, 30 May 2023 22:52:38 +0200

Test Content
Testing'),
    });

    is( $tester->{authmilter}->{handler}->{SPF}->{'spfu_detected'}, 1, 'SPFU detected');
    my $result = $tester->get_authresults_header()->search({ 'key' => 'spf' })->children()->[0]->value;
    is( $result, 'fail', 'spf=fail' );
    my $header = $tester->get_authresults_header()->search({ 'key' => 'spf' })->as_string;
    my $expect = 'spf=fail smtp.mailfrom=test@foobar.spfuvictim.com smtp.helo=mx.example.com (spf pass downgraded due to suspicious path)';
    is( $header, $expect, 'SPF downgraded comment found in fail header' );

};

for my $in_header (@headers) {
    my ($header_type) = $in_header =~ /(.*): .*/;
    subtest "spfu detection individual header $header_type" => sub {

        $tester->switch( 'new' );
        $tester->run({
            'connect_ip' => '1.2.3.4',
            'connect_name' => 'mx.example.com',
            'helo' => 'mx.example.com',
            'mailfrom' => 'test@foobar.spfuvictim.com',
            'rcptto' => [ 'test@example.net' ],
            'body' => join( "\n", $in_header,
'From: Test <localpart@foobar.spfuvictim.com>
Subject: Test
To: email_address@example.com
Date: Tue, 30 May 2023 22:52:38 +0200

Test Content
Testing'),
    });

        is( $tester->{authmilter}->{handler}->{SPF}->{'spfu_detected'}, 1, 'SPFU detected');
        my $result = $tester->get_authresults_header()->search({ 'key' => 'spf' })->children()->[0]->value;
        is( $result, 'fail', 'spf=fail' );
        my $header = $tester->get_authresults_header()->search({ 'key' => 'spf' })->as_string;
        my $expect = 'spf=fail smtp.mailfrom=test@foobar.spfuvictim.com smtp.helo=mx.example.com (spf pass downgraded due to suspicious path)';
        is( $header, $expect, 'SPF downgraded comment found in fail header' );
    };

}

subtest 'unrelated domain' => sub {

    $tester->switch( 'new' );
    $tester->run({
        'connect_ip' => '1.2.3.4',
        'connect_name' => 'mx.example.com',
        'helo' => 'mx.example.com',
        'mailfrom' => 'test@foobar.spfuvictim.com',
        'rcptto' => [ 'test@example.net' ],
        'body' => 'ARC-Authentication-Results: i=1; mx.microsoft.com 1; spf=fail (sender ip is 23.26.253.8) smtp.rcpttodomain=gmail.com smtp.mailfrom=innocentvictim.com; dmarc=fail (p=reject sp=reject pct=100) action=oreject header.from=foobar.innocentvictim.com; dkim=none (message not signed); arc=none
X-MS-Exchange-Authentication-Results: spf=fail (sender IP is 23.26.253.8) smtp.mailfrom=innocentvictim.com; dkim=none (message not signed) header.d=none;dmarc=fail action=oreject header.from=foobar.innocentvictim.com;
Received-SPF: Fail (protection.outlook.com: domain of innocentvictim.com does not designate 23.26.253.8 as permitted sender) receiver=protection.outlook.com; client-ip=23.26.253.8; helo=fa83.windbound.org.uk;
Received: from fa83.windbound.org.uk (23.26.253.8) by BN7NAM10FT042.mail.protection.outlook.com (10.13.156.218) with Microsoft SMTP Server id 15.20.6455.22 via Frontend Transport; Tue, 30 May 2023 20:53:10 +0000
From: Test <localpart@foobar.spfuvictim.com>
Subject: Test
To: email_address@example.com
Date: Tue, 30 May 2023 22:52:38 +0200

Test Content
Testing',
    });

    is( $tester->{authmilter}->{handler}->{SPF}->{'spfu_detected'}, undef, 'SPFU not detected');
    my $result = $tester->get_authresults_header()->search({ 'key' => 'spf' })->children()->[0]->value;
    is( $result, 'pass', 'spf=pass' );

};

done_testing;
