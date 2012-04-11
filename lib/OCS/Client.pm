use utf8;
use strict;
use warnings;

package OCS::Client;
# ABSTRACT: A simple interface to OCS's SOAP API

use Carp;
use URI;
use SOAP::Lite;
use XML::Entities;
use XML::Simple;

=head1 SYNOPSIS

  use OCS::Client;

  my $ocs = OCS::Client->new('http://ocs.example.com', 'user', 'passwd');

  my @computers = $ocs->get_computers_V1(id => 123456);

  my $next_computer = $ocs->computer_iterator(asking_for => 'META');
  while (my $meta = $next_computer->()) {
      # ...
  }

=head1 DESCRIPTION

OCS is a technical management solution of IT assets. It's home page is L<http://www.ocsinventory-ng.org/en/>.

This module implements a thin Object Oriented wrapper around OCS's
SOAP API, which is somewhat specified in
L<http://wiki.ocsinventory-ng.org/index.php/Developers:Web_services>.
(This version is known to work against OCS 2.0.1.)

=head2 METHODS

=method B<new> OCSURL, USER, PASSWD [, <SOAP::Lite arguments>]

The OCS::Client constructor requires three arguments. OCSURL is OCS's
base URL from which will be constructed it's SOAP URL. USER and PASSWD
are the credentials that will be used to authenticate into OCS. Any
other arguments will be passed to the L<SOAP::Lite> object that will
be created to talk to OCS.

=cut

sub new {
    my ($class, $url, $user, $pass, @args) = @_;

    my $URI = URI->new($url);

    my $proxy_uri = $URI->clone();

    my $userinfo;
    $userinfo  = $user if $user;
    $userinfo .= ':'   if $user && $pass;
    $userinfo .= $pass if $pass;

    $proxy_uri->userinfo($userinfo) if $userinfo;

    my $self = {
	soap => SOAP::Lite
	    ->uri($URI->as_string() . "/Apache/Ocsinventory/Interface")
		->proxy($proxy_uri->as_string() . "/ocsinterface\n", @args),
    };

    return bless $self, $class;
}

=method B<get_computers_V1> REQUEST-MAP

This method allows for querying inventoried computers.

The REQUEST-MAP is a key-value list of information that is used to
construct the XML request structure defined in the OCS documentation
(see link above). Any key-value pair passed to the method is appended
to the following default list:

    engine     => 'FIRST',
    asking_for => 'INVENTORY',
    checksum   => '131071',
    wanted     => '000003',
    offset     => 0,

The complete list is used to initialize a hash from which the XML
structure is built. Hence, you can override any one of the default
values by respecifying it.

The method returns a list of hashes. Each hash represents a computer
as a data structure that is converted from its XML original
representation into a Perl data structure by the XML::Simple::XMLin
function.

=cut

sub get_computers_V1 {
    my $self = shift;
    my %request = (
	engine     => 'FIRST',
	asking_for => 'INVENTORY',
	checksum   => '131071',
	wanted     => '000003',
	offset     => 0,
	@_,
    );

    my $request = "<REQUEST>\n";
    while (my ($tag, $value) = each %request) {
	$request .= "  <\U$tag\E>$value</\U$tag\E>\n";
    }
    $request .= "</REQUEST>\n";

    my $som = $self->{soap}->get_computers_V1($request);

    die "ERROR: ", XML::Entities::decode('all', $som->fault->{faultstring})
	if $som->fault;

    my @computers = $som->paramsall;

    # peel of the <COMPUTERS> tag of @computers
    shift @computers;
    pop   @computers;

    return map {XMLin($_, ForceArray => [qw/DRIVES NETWORKS PRINTERS SOFTWARES VIDEOS/])} @computers;
}

=method B<computer_iterator> REQUEST-LIST

This method returns a closure that you can use to fetch the computers
one by one until there is no more. It's usefull because the server
usually has a limit to the maximum number of computers that
get_computers_V1 can return at once. See an example of its usage in
the SYNOPSIS above.

=cut

sub computer_iterator {
    my ($self, %request) = @_;
    my @computers;
    my $offset = 0;
    return sub {
	unless (@computers) {
	    @computers = $self->get_computers_V1(%request, offset => $offset);
	    ++$offset;
	}
	return shift @computers;
    };
}

# This hash is used to map OCS custom field ids (in the form
# "fields_N") into their names.
our %fields = (
    3 => 'UA',
    4 => 'Sala',
    5 => 'Nome do Usuário',
    6 => 'Atividade',
    7 => 'Nome da Empresa',
    8 => 'Ponto de Rede',
    9 => 'Switch',
    10 => 'Porta',
    11 => 'Status',
    13 => 'Observações',
    14 => 'Local do Ponto',
    15 => 'Asset Number',
    16 => 'Responsável',
    17 => 'Tipo',
    18 => 'Padrão de HW',
    19 => 'Data de Aquisição',
    20 => 'UA Username',
    21 => 'Office',
    22 => 'Office Tag',
);

=method B<prune> COMPUTER

This class method gets a COMPUTER description, as returned by the
get_computer_V1 method, and simplifies it by deleting and converting
some not so important information. It returns the simplified data
structure.

Its original motivation was to get rid of unimportant information and
turn it into the barest minimum that I wanted to save in a text file
(after converting it into JSON) that I kept under version
control. Without pruning the repository became unecessarily big and
there were lots of frequently changing information that was
uninportant to track.

Note that it tries to convert the custom field names by using the
OCS::Client::fields hash. This hash contains by default, the custom
field names of my company's OCS instance. You should redefine it in
your script if you intend to use this method. (The source be with you,
Luke!)

=cut

sub prune {
    my ($computer) = @_;

    foreach (my ($key, $accountinfo) = each %{$computer->{ACCOUNTINFO}}) {
	my %myinfo;
	foreach my $info (grep {exists $_->{content}} @$accountinfo) {
	    if ($info->{Name} =~ /^fields_(\d+)$/) {
		$myinfo{$fields{$1}} = $info->{content};
	    } else {
		$myinfo{$info->{Name}} = $info->{content};
	    }
	}

	delete $myinfo{'UA Username'};

	$computer->{ACCOUNTINFO}{$key} = \%myinfo;
    }

    if (exists $computer->{DRIVES}) {
	foreach my $drive (@{$computer->{DRIVES}}) {
	    $drive->{ORDER} = (ref $drive->{VOLUMN} ? '' : $drive->{VOLUMN}) . (ref $drive->{LETTER} ? '' : $drive->{LETTER});
	    delete @{$drive}{qw/CREATEDATE FREE LETTER NUMFILES VOLUMN/};
	}
	$computer->{DRIVES} = [sort {$a->{ORDER} cmp $b->{ORDER}} grep {$_->{TYPE} !~ /removable/i} @{$computer->{DRIVES}}];
    }

    if (exists $computer->{HARDWARE}) {
	delete @{$computer->{HARDWARE}}{qw/FIDELITY LASTCOME IPADDR IPSRC LASTDATE PROCESSORS QUALITY USERID SWAP/};
	$computer->{HARDWARE}{DESCRIPTION} =~ s@^([^/]+)/\d\d-\d\d-\d\d \d\d:\d\d:\d\d$@$1@;
    }

    if (exists $computer->{NETWORKS}) {
	foreach my $net (@{$computer->{NETWORKS}}) {
	    delete @{$net}{qw/SPEED STATUS/};
	}
    }

    $computer->{PRINTERS} = [sort {$a->{NAME} cmp $b->{NAME}} @{$computer->{PRINTERS}}]
	if exists $computer->{PRINTERS};

    # Of the software we only keep the name and the version
    $computer->{SOFTWARES} = {map {($_->{NAME} => $_->{VERSION})} @{$computer->{SOFTWARES}}}
	if exists $computer->{SOFTWARES};

    if (exists $computer->{VIDEOS}) {
	foreach my $video (@{$computer->{VIDEOS}}) {
	    delete @{$video}{qw/RESOLUTION/};
	}
    }

    return $computer;
}

1; # End of OCS::Client
