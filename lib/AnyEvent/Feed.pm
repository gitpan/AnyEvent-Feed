package AnyEvent::Feed;
use strict;
no warnings;

use Carp qw/croak/;
use Encode;
use XML::Feed;
use AnyEvent::HTTP;
use Digest::SHA1 qw/sha1_base64/;
use Scalar::Util qw/weaken/;

our $VERSION = '0.1';

=head1 NAME

AnyEvent::Feed - Receiving RSS/Atom Feed reader with XML::Feed

=head1 VERSION

Version 0.1

=head1 SYNOPSIS

   use AnyEvent;
   use AnyEvent::Feed;

   my $feed_reader =
      AnyEvent::Feed->new (
         url   => 'http://example.com/atom.xml',
      );

   $feed_reader->fetch (sub {
      my ($feed_reader, $new_entries, $feed, $error) = @_;

      if (defined $error) {
         warn "ERROR: $error\n";
         return;
      }

      # $feed is the XML::Feed object belonging to that fetch.

      for (@$new_entries) {
         my ($hash, $entry) = @_;
         # $hash a unique hash describing the $entry
         # $entry is the XML::Feed::Entry object of the new entries
         # since the last fetch.
      }
   });

   # Or:

   my $feed_reader =
      AnyEvent::Feed->new (
         url      => 'http://example.com/atom.xml',
         interval => $seconds,

         on_fetch => sub {
            my ($feed_reader, $new_entries, $feed, $error) = @_;

            if (defined $error) {
               warn "ERROR: $error\n";
               return;
            }

            # see above
         }
      );

=head1 DESCRIPTION

This module implements some glue between L<AnyEvent::HTTP> and L<XML::Feed>.
It can fetch a RSS/Atom feed on a regular interval as well as on customized
times. It also keeps track of already fetched entries so that you will only get
the new entries.

=head1 METHODS

=over 4

=item $feed_reader = AnyEvent::Feed->new (url => $url, %args)

This is the constructor for a new feed reader for the RSS/Atom feed
reachable by the URL C<$url>. C<%args> may contain additional key/value pairs:

=over 4

=item interval => $seconds

If this is set you also have to specify the C<on_fetch> callback (see below).
It will try to fetch the C<$url> every C<$seconds> seconds and call the
callback given by C<on_fetch> with the result.

=item on_fetch => $cb->($feed_reader, $new_entries, $feed_obj, $error)

This callback is called if the C<interval> parameter is given (see above)
with the same arguments as the callback given to the C<fetch> method (see below).

=item entry_ages => $hash

This will set the hash which keeps track of seen and old entries.
See also the documentation of the C<entry_ages> method below.
The default will be an empty hash reference.

=item max_entry_age => $count

This will set the maximum number of times an entry is kept in the C<entry_ages>
hash after it has not been seen in the feed anymore. The default value is 2
which means that an entry hash is removed from the C<entry_ages> hash after it
has not been seen in the feed for 2 fetches.

=back

=cut

sub new {
   my $this  = shift;
   my $class = ref($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->{entry_ages} ||= {};

   if (defined $self->{interval}) {
      unless (defined $self->{on_fetch}) {
         croak "no 'on_fetch' callback given!";
      }

      my $wself = $self;
      weaken $wself;

      $self->{timer_cb} = sub {
         $wself->fetch (sub {
            my ($self, $e, $f, $err) = @_;

            $self->{on_fetch}->($self, $e, $f, $err);
            $self->{timer} =
               AnyEvent->timer (
                  after => $self->{interval}, cb => $self->{timer_cb});
         })
      };

      $self->{timer_cb}->();
   }

   return $self
}


sub _entry_to_hash {
   my ($entry) = @_;
   my $x = sha1_base64
      encode 'utf-8',
         (my $a = join '/',
            $entry->title,
            ($entry->summary  ? $entry->summary->body : ''),
            ($entry->content  ? $entry->content->body : ''),
            $entry->id,
            $entry->link);
   $x
}

sub _new_entries {
   my ($self) = @_;

   $self->{entry_ages} ||= {};

   my (@ents) = $self->{feed}->entries;

   my @new;

   # 'age' the old entries
   $self->{entry_ages}->{$_}++ for keys %{$self->{entry_ages}};

   for my $ent (@ents) {
      my $hash = _entry_to_hash ($ent);

      unless (exists $self->{entry_ages}->{$hash}) {
         push @new, [$hash, $ent];
      }

      $self->{entry_ages}->{$hash} = 0; # reset age of old entry.
   }

   for (keys %{$self->{entry_ages}}) {
      delete $self->{entry_ages}->{$_}
         if $self->{entry_ages}->{$_} > $self->{max_entry_ages};
   }

   \@new
}

=item $feed_reader->url

Just returns the url that this feed reader is fetching from.

=cut

sub url { $_[0]->{url} }

=item $feed_reader->entry_ages ($new_entry_ages)

=item my $entry_ages = $feed_reader->entry_ages

This will set the age hash which will keep track of already seen entries.
The keys of the hash will be the calculated hashes of the entries and the
values will be a counter of how often they have NOT been seen anymore (kind of
an age counter). After each fetch this hash is updated and seen entries get
a value of 0.

=cut

sub entry_ages {
   defined $_[1]
      ? $_[0]->{entry_ages} = $_[1]
      : $_[0]->{entry_ages}
}

=item $feed_reader->fetch ($cb->($feed_reader, $new_entries, $feed_obj, $error))

This will initiate a HTTP GET on the URL passed to C<new> and call C<$cb> when
done.

C<$feed_reader> is the feed reader object itself.  C<$new_entries> is an
array reference containing the new entries.  A new entry in that array is
another array containing a calculated hash over the contents of the new entry,
and the L<XML::Feed::Entry> object of that entry.  C<$feed_obj> is the
L<XML::Feed> feed object used to parse the fetched feed and contains all
entries (and not just the 'new' ones).

What a 'new' entry is, is decided by a map of hashes as described in the C<entry_ages>
method's documentation above.

=cut

sub fetch {
   my ($self, $cb) = @_;

   unless (defined $cb) {
      croak "no callback given to fetch!";
   }

   http_get $self->{url}, sub {
      my ($data, $hdr) = @_;

      if ($hdr->{Status} =~ /^2/) {
         my $feed;
         eval {
            $self->{feed} = XML::Feed->parse (\$data);
         };
         if ($@) {
            $cb->($self, undef, undef, "exception: $@");
         } elsif (not defined $self->{feed}) {
            $cb->($self, undef, undef, XML::Feed->errstr);
         } else {
            $cb->($self, $self->_new_entries, $self->{feed});
         }
      } else {
         $cb->($self, undef, undef, "$hdr->{Status} $hdr->{Reason}");
      }
   };
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

L<XML::Feed>

L<AnyEvent::HTTP>

L<AnyEvent>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-anyevent-feed at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=AnyEvent-Feed>.
I will be notified and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc AnyEvent::Feed

You can also look for information at:

=over 4

=item * IRC: AnyEvent::Feed IRC Channel

See the same channel as the L<AnyEvent::XMPP> module:

  IRC Network: http://freenode.net/
  Server     : chat.freenode.net
  Channel    : #ae_xmpp

  Feel free to join and ask questions!

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/AnyEvent-Feed>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/AnyEvent-Feed>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=AnyEvent-Feed>

=item * Search CPAN

L<http://search.cpan.org/dist/AnyEvent-Feed>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
