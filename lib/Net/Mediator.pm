package Net::Mediator;

=head1 NAME

Package::Package - Name-of-package - short description of package

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

Package::Package 

long 

description 

of package

=head3 Usage

For example

    use Package::Package;
    my $Package = Package::Package->new();
    $package->do_something();

Is about the least code needed to do something useful

=head3 Usage

For example:

    use Package::Package;
    my $Package = Package::Package->new();
    $package->do_something();
    $package->do_something_else();
    $package->do_something_more();
    $package->do_something_other();

Introduces all the main options

=head1 SUBROUTINES/METHODS

=cut

# #######
# Globals
# #######

use 5.002;
use warnings FATAL => 'all';
#use Socket;
#use FileHandle;
#use IO::Handle;
use Net::MitM;
use Carp;
@ISA=qw(Net::MitM);

use strict;

=head2 new( local_port_num, remote_ip_address, remote_port_num, forward_translate_callback, back_translate_callback )

Creates a new mediator

=head4 Parameters

=over

=item * local_port_num - the port number to listen on

=item * remote_ip_address, remote_port_number - the server to connect to

=item * forward/back translate_callback - a function to do translations

=item * Returns - the mediator object

=back

=head4 Usage

For example:

    use Net::Mediator;
    my %forward_translations = (
      'a=(?<a>.+?),b=(?<b>.+?),c=(?<c>.+?);' => '<a>$+{a}</a><b>$+{b}</b><c>$+{c}</c>',
      );
    my %back_translations = (
      '<(.)>(.*?)</\1><(.)>(.*?)</\3><(.)>(.*?)</\5>' => '$1=$2,$3=$4,$5=$6;'
      );
    my $forward_translator = Net::Mediator->new_translator(\%forward_translations);
    my $back_translator = Net::Mediator->new_translator(\%back_translations);
    my $forward_translate = sub{$translator->translate(@_)};
    my $back_translate = sub{$translator->translate(@_)};
    my $mediator = Net::Mediator->new($remote_host,$remote_port,$local_port,$forward_translate,$back_translate);
    $mediator->go();

=cut 

sub new(@) {
  my $class=shift;
  my $local_port_num = shift or croak "local port number missing";
  my $remote_ip_address = shift or croak "remote hostname/ip address missing";
  my $remote_port_num = shift or croak "remote port number missing";
  my $forward_translator = shift or croak "forward translator missing";
  my $back_translator = shift or croak "back translator missing";
  my $mitm=Net::MitM->new($remote_ip_address, $remote_port_num, $local_port_num);
  $mitm->client_to_server_callback($forward_translator,callback_behaviour=>'modify');
  $mitm->server_to_client_callback($back_translator,callback_behaviour=>'modify');
  $mitm->name("Mediator");
  return $mitm; # The mediator is an instance of a MitM, not an instance of some child class
}


=head2 new_translator( translations )

Creates a new translator for the given translations.


It should not normally be necessary to call these methods directly.

=head4 Parameters

=over

=item * translations - a hash table of from/to translations.  Each 'from' should be a string which will be used as a regular expression. Each 'to' should be a string, which may rely on the regular expression having matched.

=item * Returns - a new translator. The translator only has one method, translate().

=back

=head4 Usage

For example:

    my %translations = { 'hello' => 'hi there', '(?<key>.+?)=(?<value>.+?)' => '<$+{key}>$+{value}</$+key>' };
    my $translator = Net::Mediator->new_translator(\%translations);
    say $translator->translate('hello'); # prints "hello"
    say $translator->translate('a=b');   # prints "<a>b</a>"

Translations are tested in effectively random order, and translation stops after the first match.  If there are no matches, undef is returned.

=cut 

#TODO put this in its own package

sub new_translator(\%)
{
  my $class=shift;
  my $translations=shift; # TODO should check that translations is a hash table
  my %this;
  while(my ($from,$to) = each %{$translations}) {
    $this{qr{$from}ms} = $to;
  }
  return bless(\%this, $class);
}

sub translate($)
{
  my $this=shift or die;
  my $in=shift or die;
  #while(my ($from,$to) = each %{$this}) {
  foreach my $from (keys %{$this}) {
    if($in =~ $from){
      my $to=$this->{$from};
      return eval qq{qq{$to}}; # expand $to into a string
    }
  }
  return undef;
}

=head1 Exports

Package does not export any functions or variables.  

=head1 AUTHOR

Ben AVELING, C<< <ben dot aveling at optusnet dot com dot au> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-Net-MitM at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-MitM>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Package::Package

You can also look for information at:

=over

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-MitM>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-MitM>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-MitM>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-MitM/>

=back

=head1 ACKNOWLEDGEMENTS

I'd like to acknowledge someone I haven't acknowledge in any other package I've yet written.

=head1 ALTERNATIVES

Another Package, if any.

=head1 LICENSE AND COPYRIGHT

Copyleft 2013 Ben AVELING.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, have, hold and cherish,
use, offer to use, sell, offer to sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. SO THERE.

=cut

1; # End of package Net::MitM::Mediator;
