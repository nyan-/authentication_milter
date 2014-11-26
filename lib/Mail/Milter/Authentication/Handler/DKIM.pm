package Mail::Milter::Authentication::Handler::DKIM;

use strict;
use warnings;

our $VERSION = 0.4;

use base 'Mail::Milter::Authentication::Handler::Generic';

use Sys::Syslog qw{:standard :macros};

use Mail::DKIM::Verifier;

sub envfrom_callback {
    my ( $self, $env_from ) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_dkim'} );
    $self->{'failmode'} = 0;
    my $dkim;
    eval {
        $dkim = Mail::DKIM::Verifier->new();
        $self->{'obj'} = $dkim;
    };
    if ( my $error = $@ ) {
        $self->log_error( 'DMKIM Setup Error ' . $error );
        $self->add_auth_header('dkim=temperror');
        $self->{'failmode'} = 1;
    }
}

sub header_callback {
    my ( $self, $header, $value ) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_dkim'} );
    return if ( $self->{'failmode'} );
    my $dkim       = $self->{'obj'};
    my $EOL        = "\015\012";
    my $dkim_chunk = $header . ': ' . $value . $EOL;
    $dkim_chunk =~ s/\015?\012/$EOL/g;
    $dkim->PRINT($dkim_chunk);

    # Add Google signatures to the mix.
    # Is this wise?
    if ( $header eq 'X-Google-DKIM-Signature' ) {
        my $x_dkim_chunk = 'DKIM-Signature: ' . $value . $EOL;
        $x_dkim_chunk =~ s/\015?\012/$EOL/g;
        $dkim->PRINT($x_dkim_chunk);
    }
}

sub eoh_callback {
    my ($self) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_dkim'} );
    return if ( $self->{'failmode'} );
    my $dkim = $self->{'obj'};
    $dkim->PRINT("\015\012");
}

sub body_callback {
    my ( $self, $body_chunk, $len ) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_dkim'} );
    return if ( $self->{'failmode'} );
    my $dkim       = $self->{'obj'};
    my $dkim_chunk = $body_chunk;
    my $EOL        = "\015\012";
    $dkim_chunk =~ s/\015?\012/$EOL/g;
    $dkim->PRINT($dkim_chunk);
}

sub eom_callback {
    my ($self) = @_;
    my $CONFIG = $self->config();
    return if ( !$CONFIG->{'check_dkim'} );
    return if ( $self->{'failmode'} );
    my $dkim = $self->{'obj'};
    eval {
        $dkim->CLOSE();

        my $dkim_result        = $dkim->result;
        my $dkim_result_detail = $dkim->result_detail;

        $self->dbgout( 'DKIMResult', $dkim_result_detail, LOG_INFO );

        if ( !$dkim->signatures ) {
            if ( !( $CONFIG->{'check_dkim'} == 2 && $dkim_result eq 'none' ) ) {
                $self->add_auth_header(
                    $self->format_header_entry( 'dkim', $dkim_result )
                      . ' (no signatures found)' );
            }
        }
        foreach my $signature ( $dkim->signatures ) {

            $self->dbgout( 'DKIMSignatureIdentity', $signature->identity, LOG_DEBUG );
            $self->dbgout( 'DKIMSignatureResult',   $signature->result_detail, LOG_DEBUG );
            my $signature_result        = $signature->result();
            my $signature_result_detail = $signature->result_detail();

            my $result_comment = q{};
            if ( $signature_result ne 'pass' and $signature_result ne 'none' ) {
                $signature_result_detail =~ /$signature_result \((.*)\)/;
                $result_comment = $1 . '; ';
            }
            if (
                !(
                    $CONFIG->{'check_dkim'} == 2 && $signature_result eq 'none'
                )
              )
            {
                my $otype = ref $signature;
                my $type =
                    $otype eq 'Mail::DKIM::DkSignature' ? 'domainkeys'
                  : $otype eq 'Mail::DKIM::Signature'   ? 'dkim'
                  :                                       'dkim';
                $self->dbgout( 'DKIMSignatureType', $type, LOG_DEBUG );

                my $key_data = q{};
                eval {
                    my $key = $signature->get_public_key();
                    $key_data = $key->size() . '-bit ' . $key->type() . ' key';
                };

                if ( $type eq 'domainkeys' ) {
                    ## DEBUGGING
                    my $header = join(
                        q{ },
                        $self->format_header_entry( $type, $signature_result ),
                        '('
                          . $self->format_header_comment(
                              $result_comment
                              . $key_data
                            )
                          . ')',
                        $self->format_header_entry( 'header.d', $signature->domain() ),
                        $self->format_header_entry( 'header.b', substr( $signature->data(), 0, 8 ) ),
                    );
                    $self->add_auth_header($header);
                }
                else {
                    my $header = join(
                        q{ },
                        $self->format_header_entry( $type, $signature_result ),
                        '('
                          . $self->format_header_comment(
                            $result_comment
                            . $key_data
                          )
                          . ')',
                        $self->format_header_entry( 'header.d', $signature->domain() ),
                        $self->format_header_entry( 'header.i', $signature->identity() ),
                        $self->format_header_entry( 'header.b', substr( $signature->data(), 0, 8 ) ),
                    );
                    $self->add_auth_header($header);
                }
            }
        }

        # the alleged author of the email may specify how to handle email
        if (   $CONFIG->{'check_dkim-adsp'}
            && ( $self->is_local_ip_address() == 0 )
            && ( $self->is_trusted_ip_address() == 0 )
            && ( $self->is_authenticated() == 0 ) )
        {
            foreach my $policy ( $dkim->policies ) {
                my $apply    = $policy->apply($dkim);
                my $string   = $policy->as_string();
                my $location = $policy->location() || q{};
                my $name     = $policy->name();
                my $default  = $policy->is_implied_default_policy();

                my $otype = ref $policy;
                my $type =
                    $otype eq 'Mail::DKIM::AuthorDomainPolicy' ? 'dkim-adsp'
                  : $otype eq 'Mail::DKIM::DkimPolicy'         ? 'x-dkim-ssp'
                  : $otype eq 'Mail::DKIM::DkPolicy'           ? 'x-dkim-dkssp'
                  :   'x-dkim-policy';

                $self->dbgout( 'DKIMPolicy',         $apply,    LOG_DEBUG );
                $self->dbgout( 'DKIMPolicyString',   $string,   LOG_DEBUG );
                $self->dbgout( 'DKIMPolicyLocation', $location, LOG_DEBUG );
                $self->dbgout( 'DKIMPolicyName',     $name,     LOG_DEBUG );
                $self->dbgout( 'DKIMPolicyDefault', $default ? 'yes' : 'no',
                    LOG_DEBUG );

                my $result =
                    $apply eq 'accept'  ? 'pass'
                  : $apply eq 'reject'  ? 'discard'
                  : $apply eq 'neutral' ? 'unknown'
                  :                       'unknown';

                if ( ! ( $CONFIG->{'check_dkim-adsp'} == 2 && $result eq 'none' ) ) {
                    if ( ( ! $default ) or $CONFIG->{'show_default_adsp'} ) {
                        my $comment = '('
                          . $self->format_header_comment( ( $default ? 'default ' : q{} )
                            . "$name policy"
                            . ( $location ? " from $location" : q{} )
#                            . ( $string   ? "; $string"       : q{} )
                          )
                          . ')';

                        my $header = join( q{ },
                            $self->format_header_entry( $type, $result ), $comment, );
                        $self->add_auth_header( $header );
                    }
                }
            }
        }
    };
    if ( my $error = $@ ) {
        $self->log_error( 'DKIM Error - ' . $error );
        $self->add_auth_header('dkim=temperror');
        $self->{'failmode'} = 1;
        delete $self->{'obj'};
    }
}

1;
