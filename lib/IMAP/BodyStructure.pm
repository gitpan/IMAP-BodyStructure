package IMAP::BodyStructure;
use strict;

# $from-Id: BodyStructure.pm,v 1.23 2004/07/06 13:53:24 kappa Exp $
# $Id: BodyStructure.pm,v 1.6 2004/07/07 11:44:15 kappa Exp $

=head1 NAME

IMAP::BodyStructure - IMAP4-compatible BODYSTRUCTURE and ENVELOPE parser

=head1 SYNOPSIS
    
    use IMAP::BodyStructure;

    # $imap is a low-level IMAP-client with an ability to fetch items
    # by message uids

    my $bs = new IMAP::BodyStructure
        $imap->imap_fetch($msg_uid,
                'BODYSTRUCTURE', 1)->[0]->{BODYSTRUCTURE};

    print "[UID:$msg_uid] message is in Russian. Sure.\n"
        if $bs->charset =~ /(?:koi8-r|windows-1251)/i;

    my $part = $bs->part_at('1.3');
    $part->type =~ m#^image/#
        and print "The 3rd part is an image named \""
            . $part->filename . "\"\n";

=head1 DESCRIPTION

An IMAP4-compatible IMAP server MUST include a full MIME-parser which
parses the messages inside IMAP mailboxes and is accessible via
BODYSTRUCTURE fetch item. This module provides a perl interface to
parse the output of IMAP4 MIME-parser. Hope no one will have problems
with parsing this doc.

It is a rather straightforward C<m/\G.../gc>-style parser and is
therefore much, much faster then the venerable L<Mail::IMAPClient::BodyStructure>
which is based on a L<Parse::RecDescent> grammar. I believe it also to be
more correct when parsing nested multipart C<message/rfc822> parts. See
testsuite if interested.

I'd also like to emphasize that I<this module does not contain IMAP4
client!> You will need to employ one from CPAN, there are many. A
section with examples of getting to a BODYSTRUCTURE fetch item with
various Perl IMAP clients available on CPAN will of course greatly
enhance this document.

=head1 INTERFACE

=cut

use 5.005;

use vars qw/$VERSION/;

$VERSION = '0.81';

sub get_envelope(\$);
sub _get_bodystructure(\$;$);
sub _get_npairs(\$);
sub _get_ndisp(\$);
sub _get_nstring(\$);

=head2 METHODS

=over 4

=item new($)

The constructor does most of the work here. It initializes the
hierarchial data structure representing all the message parts and their
properties. It takes one argument which should be a string returned
by IMAP server in reply to a FETCH command with BODYSTRUCTURE item.

All the parts on all the levels are represented by IMAP::BodyStructure
objects and that enables the uniform access to them. It is a direct
implementation of the Composite Design Pattern.

=cut

sub new {
    my $class   = shift;
    $class      = ref $class if ref $class;

    my $imap_bs = shift;
    my $bs;

    $bs = _get_bodystructure($imap_bs);
    $bs->{part_id} ||= 1;   # single-part has one part with id 1

    bless $bs, $class;
}

=item type()

Returns the MIME type of the part. Expect something like C<text/plain>
or C<application/octet-stream>.

=item encoding()

Returns the MIME encoding of the part. This is usually one of '7bit',
'8bit', 'base64' or 'quoted-printable'.

=item size()

Returns the size of the part in octets. It is I<NOT> the size of the
data in the part, which may be very well quoted-printable encoded
leaving us without a method of calculating the exact size of original
data.

=cut

for my $field (qw/type encoding size/) {
    eval <<"EOC"
sub $field {
    return \$_[0]->{$field};
}
EOC
}

=item disp()

Returns the content-disposition of the part. One of 'inline' or
'attachment'. Use case-insensitive comparisons.

=cut

sub disp {
    my $self = shift;

    return $self->{disp}->[0];
}

=item charset()

Returns the charset of the part OR the charset of the first nested
part. This looks like a good heuristic really. Charset is something
resembling 'UTF-8', 'US-ASCII', 'ISO-8859-13' or 'KOI8-R'. The standard
does not say it should be uppercase, by the way.

Can be undefined.

=cut

sub charset {
    my $self = shift;

    # get charset from params OR dive into the first part
    return $self->{params}->{charset}
        || ($self->{parts} && @{$self->{parts}} && $self->{parts}->[0]->charset);
}

=item filename()

Returns the filename specified as a part of Content-Disposition
header.

Can be undefined.

=cut

sub filename {
    my $self = shift;

    return $self->{disp}->[1]->{filename};
}

=item description()

Returns the description of the part.

=cut

sub description {
    my $self = shift;

    return $self->{desc};
}

=item parts(;$)

This sub acts differently depending on whether you pass it an
argument or not.

Without any arguments it returns a list of parts in list context and
the number in scalar context.

Specifying a scalar argument allows you to get an individual part with
that index.

I<Remember, all the parts I talk here about are not actual message data, files
etc. but IMAP::BodyStructure objects containing information about the
message parts which was extracted from parsing BODYSTRUCTURE IMAP
response!>

=cut

sub parts {
    my $self = shift;
    my $arg = shift;

    if (defined $arg) {
        return $self->{parts}->[$arg];
    } else {
        return wantarray ? @{$self->{parts}} : scalar @{$self->{parts}};
    }
}

=item part_at($)

This method returns a message part by its path. A path to a part in
the hierarchy is a dot-separated string of part indices. See L</SYNOPSIS> for
an example. A nested C<message/rfc822> always has exactly one nested
part which represents the internal IMAP::BodyStructure object. Look,
here is an outline of an example message structure with part paths alongside
each part.

    multipart/mixed                   1
        text/plain                    1.1
        application/msword            1.2
        message/rfc822                1.3
            multipart/alternative     1.3.1
                text/plain            1.3.1.1
                multipart/related     1.3.1.2
                    text/html         1.3.1.2.1
                    image/png         1.3.1.2.2
                    image/png         1.3.1.2.3

This is a text email with two attachments, one being a word document,
and the other is itself a message (probably a forward) which is composed in a
graphical MUA and contains two alternative representations, one
plain text fallback and one HTML with images (bundled as a
C<multipart/related>).

=cut

sub part_at {
    my $self = shift;
    my $path = shift;

    return $self->_part_at(split /\./, $path);
}

sub _part_at {
    my $self = shift;
    my @parts = @_;
    
    my $part_num = shift @parts
        or return $self;

    if ($self->type =~ /^multipart\//) {
        return $self->{parts}->[$part_num - 1]->_part_at(@parts);
    } elsif ($self->type eq 'message/rfc822') {
        warn "part_at trying to get $part_num part of a message/rfc822\n"
            unless $part_num == 1;
        return $self->{bodystructure}->_part_at(@parts);
    } else {
        return $self;
    }
}

=item part_path()

Returns the part path to the current part.

=back

=head2 DATA MEMBERS

These are additional pieces of information returned by IMAP server and
parsed. They are rarely used, though (and rarely defined too, btw), so
I chose not to provide access methods for them.

=over 4

=item params

This is a hashref of MIME parameters. The only interesting param is
charset and there's a shortcut method for it.

=item lang

Content language.

=item loc

Content location.

=item cid

Content ID.

=item md5

Content MD5. No one seems to bother with calculating and it is usually
undefined.

=back

B<cid> and B<md5> members exist only in singlepart parts.

=cut

sub part_path {
    my $self = shift;

    return $self->{part_id};
}

sub get_envelope(\$) {
    IMAP::BodyStructure::Envelope->new($_[0]);
}

sub _get_bodystructure(\$;$) {
    my $str = shift;
    my $id  = shift;
    my %bs = ( part_id => $id );

    $$str =~ m/\G\s*(?:\(BODYSTRUCTURE)?\s*\(/gc
        or return 0;

    if ($$str =~ /(?=\()\G/gc) {
        # multipart
        $bs{type}       = 'multipart/';
        $bs{parts}      = [];
        my $part_id = 1;
        while (my $part_bs = _get_bodystructure($$str, ($id ? "$id." : '') . $part_id++)) {
            push @{$bs{parts}}, $part_bs;
        }

        $bs{type}      .= lc(_get_nstring($$str));
        $bs{params}     = _get_npairs($$str);
        $bs{disp}       = _get_ndisp($$str);
        $bs{lang}       = _get_nstring($$str);
        $bs{loc}        = _get_nstring($$str);
    } else {
        $bs{type}       = lc (_get_nstring($$str) . '/' . _get_nstring($$str));
        $bs{params}     = _get_npairs($$str);
        $bs{cid}        = _get_nstring($$str);
        $bs{desc}       = _get_nstring($$str);
        $bs{encoding}   = _get_nstring($$str);
        $bs{size}       = _get_nstring($$str);

        if ($bs{type} eq 'message/rfc822') {
            $bs{envelope}       = get_envelope($$str);
            $bs{bodystructure}  = _get_bodystructure($$str, ($id ? "$id." : '') . 1);
            $bs{textlines}      = _get_nstring($$str);
        } elsif ($bs{type}      =~ /^text\//) {
            $bs{textlines}      = _get_nstring($$str);
        }

        $bs{md5}  = _get_nstring($$str);
        $bs{disp} = _get_ndisp($$str);
        $bs{lang} = _get_nstring($$str);
        $bs{loc}  = _get_nstring($$str);
    }

    $$str =~ m/\G\s*\)/gc;

    return bless \%bs, __PACKAGE__;
}

sub _get_ndisp(\$) {
    my $str = shift;

    $$str =~ /\G\s+/gc;

    if ($$str =~ /\GNIL/gc) {
        return undef;
    } elsif ($$str =~ m/\G\s*\(/gc) {
        my @disp;

        $disp[0] = _get_nstring($$str);
        $disp[1] = _get_npairs($$str);

        $$str =~ m/\G\s*\)/gc;
        return \@disp;
    }
    
    return 0;
}

sub _get_npairs(\$) {
    my $str = shift;

    $$str =~ /\G\s+/gc;

    if ($$str =~ /\GNIL/gc) {
        return undef;
    } elsif ($$str =~ m/\G\s*\(/gc) {
        my %r;
        while ('fareva') {
            my ($key, $data) = (_get_nstring($$str), _get_nstring($$str));
            $key or last;

            $r{$key} = $data;
        }

        $$str =~ m/\G\s*\)/gc;
        return \%r;
    }
    
    return 0;
}

sub _get_nstring(\$) {
    my $str = shift;

    # nstring         = string / nil
    # nil             = "NIL"
    # string          = quoted / literal
    # quoted          = DQUOTE *QUOTED-CHAR DQUOTE
    # QUOTED-CHAR     = <any TEXT-CHAR except quoted-specials> /
    #                  "\" quoted-specials
    # quoted-specials = DQUOTE / "\"
    # literal         = "{" number "}" CRLF *CHAR8
    #                    ; Number represents the number of CHAR8s

    # astring = 1*(any CHAR except "(" / ")" / "{" / SP / CTL / list-wildcards / quoted-specials)

    $$str =~ /\G\s+/gc;

    if ($$str =~ /\GNIL/gc) {
        return undef;
    } elsif ($$str =~ m/\G(\"(?:\\\"|(?!\").)*\")/gc) { # delimited re ala Friedl
        return _unescape($1);
    } elsif ($$str =~ /\G\{(\d+)\}\r\n/gc) {
        $$str =~ /\G(.{$1})/gcs;
        return $1;
    } elsif ($$str =~ /\G([^"\(\)\{ \%\*\"\\\x00-\x1F]+)/gc) {
        return $1;
    }

    return 0;
}

sub _unescape {
    my $str = shift;

    $str =~ s/^"//;
    $str =~ s/"$//;
    $str =~ s/\\\"/\"/g;
    $str =~ s/\\\\/\\/g;

    return $str;
}

=over 4

=item get_enveleope($)

Parses a string into IMAP::BodyStructure::Envelope object. See below.

=back

=head2 IMAP::BodyStructure::Envelope CLASS

Every message on an IMAP server has an envelope. You can get it
using ENVELOPE fetch item or, and this is relevant, from BODYSTRUCTURE
response in case there are some nested messages (parts with type of
C<message/rfc822>). So, if we have a part with such a type then the
corresponding IMAP::BodyStructure object always has
B<envelope> data member which is, in turn, an object of
IMAP::BodyStructure::Envelope.

You can of course use this satellite class on its own, this is very
useful when generating meaningful message lists in IMAP folders.

=cut

package IMAP::BodyStructure::Envelope;

sub _get_nstring(\$); # proto

*_get_nstring = \&IMAP::BodyStructure::_get_nstring;

sub _get_naddrlist(\$);
sub _get_naddress(\$);

use vars qw/@envelope_addrs/;
@envelope_addrs = qw/from sender reply-to to cc bcc/;

=head2 METHODS

=over 4

=item new($)

The constructor create Envelope object from string which should be an
IMAP server respone to a fetch with ENVELOPE item or a substring of
BODYSTRUCTURE response for a message with message/rfc822 parts inside.

=back

=head2 DATA MEMBERS

=over 4

=item date

Date of the message as specified in the envelope. Not the IMAP
INTERNALDATE, be careful!

=item subject

Subject of the message, may be RFC2047 encoded, of course.

=item mesage_id

=item in-reply-to

Message-IDs of the current message and the message in reply to which
this one was composed.

=item to, from, cc, bcc, sender, reply-to

These are the so called address-lists or just arrays of addresses.
Remember, a message may be addressed to lots of people.

Each address is a hash of four elements:

=over 4

=item name

The informal part, "A.U.Thor" from "A.U.Thor, E<lt>a.u.thor@somewhere.comE<gt>

=item sroute

Source-routing information, not used. (By the way, IMAP4r1 spec was
born after the last email address with sroute passed away.)

=item account

The part before @.

=item host

The part after @.

=item full

The full address for display purposes.

=back

=back

=cut

sub new(\$) {
    my $class = shift;
    my $str = shift;
    
    $$str =~ m/\G\s*(?:\(ENVELOPE)?\s*\(/gc
        or return 0;

    my $self = {};

    $self->{'date'}     = _get_nstring($$str);
    $self->{'subject'}  = _get_nstring($$str);

    foreach my $header (@envelope_addrs) {
        $self->{$header} = _get_naddrlist($$str);
    }

    $self->{'in-reply-to'}  = _get_nstring($$str);
    $self->{'message_id'}   = _get_nstring($$str);

    $$str =~ m/\G\s*\)/gc;

    return bless $self, $class;
}

sub _get_naddress(\$) {
    my $str = shift;

    if ($$str =~ /\GNIL/gc) {
        return undef;
    } elsif ($$str =~ m/\G\s*\(/gc) {
        my %addr = (
            name    => _get_nstring($$str),
            sroute  => _get_nstring($$str),
            account => _get_nstring($$str),
            host    => _get_nstring($$str),
        );
        $addr{address} = ($addr{account}
                ? "$addr{account}@" . ($addr{host} || '')
                : '');

        if ($addr{address} xor $addr{name}) {
            $addr{full} = $addr{name} || $addr{address};
        } else {
            # if both exist or are empty
            $addr{full} = $addr{address} ? "$addr{name} <$addr{address}>" : '';
        }

        $$str =~ m/\G\s*\)/gc;
        return \%addr;
    }
    return 0;
}

sub _get_naddrlist(\$) {
    my $str = shift;
    
    $$str =~ /\G\s+/gc;

    if ($$str =~ /\GNIL/gc) {
        return undef;
    } elsif ($$str =~ m/\G\s*\(/gc) {
        my @addrs = ();
        while (my $addr = _get_naddress($$str)) {
            push @addrs, $addr;
        }

        $$str =~ m/\G\s*\)/gc;
        return \@addrs;
    }
    return 0;
}

1;

__END__
=head1 EXAMPLES

The usual way to determine if an email has some files attached (in
order to display a cute little scrap in the message list, e.g.) is to
check whether the message is multipart or not. This method tends to
give many false positives on multipart/alternative messages with a
HTML and plaintext parts and no files. The following sub tries to be a
little smarter.

    sub _has_files {
        my $bs = shift;

        return 1 if $bs->{type} !~ m#^(?:text|multipart)/#;

        if ($bs->{type} =~ m#^multipart/#) {
            foreach my $part (@{$bs->{parts}}) {
                return 1 if _has_files($part);
            }
        }

        return 0;
    }

This snippet selects a rendering routine for a message part.

    foreach (
        [ qr{text/plain}            => \&_render_textplain  ],
        [ qr{text/html}             => \&_render_texthtml   ],
        [ qr{multipart/alternative} => \&_render_alt        ],
        [ qr{multipart/mixed}       => \&_render_mixed      ],
        [ qr{multipart/related}     => \&_render_related    ],
        [ qr{image/}                => \&_render_image      ],
        [ qr{message/rfc822}        => \&_render_rfc822     ],
        [ qr{multipart/parallel}    => \&_render_mixed      ],
        [ qr{multipart/report}      => \&_render_mixed      ],
        [ qr{multipart/}            => \&_render_mixed      ],
        [ qr{text/}                 => \&_render_textplain  ],
        [ qr{message/delivery-status}=> \&_render_textplain ],
    ) {
        $bs->type =~ $_->[0]
            and $renderer = $_->[1]
            and last;
    }

=head1 BUGS

Shouldn't be any, as this is a simple parser of a standard structure.

The documentaion is my first attempt at documenting something in
English and using POD. Almost certainly is not 100% ok.

=head1 AUTHOR

Alex Kapranoff, E<lt>kappa@rambler-co.ruE<gt>

=head1 SEE ALSO

L<Mail::IMAPClient>, L<Net::IMAP::Simple>, RFC3501, RFC2045, RFC2046.

=cut