package Mail::Milter::Authentication::PTR;

$VERSION = 0.1;

use strict;
use warnings;

use Mail::Milter::Authentication::Config qw{ get_config };
use Mail::Milter::Authentication::Util;

use Sys::Syslog qw{:standard :macros};

my $CONFIG = get_config();

sub helo_check {
    my ($ctx) = @_;
    my $priv = $ctx->getpriv();

    my $domain =
      exists( $priv->{'verified_ptr'} ) ? $priv->{'verified_ptr'} : q{};
    my $helo_name = $priv->{'helo_name'};

    if ( lc $domain eq lc $helo_name ) {
        dbgout( $ctx, 'PTRMatch', 'pass', LOG_DEBUG );
        add_c_auth_header( $ctx,
                format_header_entry( 'x-ptr', 'pass' ) . q{ }
              . format_header_entry( 'x-ptr-helo',   $helo_name ) . q{ }
              . format_header_entry( 'x-ptr-lookup', $domain ) );
    }
    else {
        dbgout( $ctx, 'PTRMatch', 'fail', LOG_DEBUG );
        add_c_auth_header( $ctx,
                format_header_entry( 'x-ptr', 'fail' ) . q{ }
              . format_header_entry( 'x-ptr-helo',   $helo_name ) . q{ }
              . format_header_entry( 'x-ptr-lookup', $domain ) );
    }

}

sub helo_callback {
    # On HELO
    my ( $ctx, $helo_host ) = @_;
    my $priv = $ctx->getpriv();
    if ( $CONFIG->{'check_ptr'} && ( $priv->{'is_local_ip_address'} == 0 ) && ( $priv->{'is_trusted_ip_address'} == 0 ) && ( $priv->{'is_authenticated'} == 0 ) ) {
        helo_check($ctx);
    }
}

1;