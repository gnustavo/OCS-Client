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

  my @computers = $ocs->get_computers_V1(
      id       => 123456,
      checksum => OCS::Client::HARDWARE | OCS::Client::SOFTWARE,
  );

  my $next_computer = $ocs->computer_iterator(asking_for => 'META');
  while (my $meta = $next_computer->()) {
      # ...
  }

=head1 DESCRIPTION

OCS is a technical management solution of IT assets. It's home page is
L<http://www.ocsinventory-ng.org/>.

This module implements a thin Object Oriented wrapper around OCS's
SOAP API, which is somewhat specified in
L<http://wiki.ocsinventory-ng.org/index.php/Developers:Web_services>.
(This version is known to work against OCS 2.0.1.)

=head2 METHODS

=head3 B<new> OCSURL, USER, PASSWD [, <SOAP::Lite arguments>]

The OCS::Client constructor requires three arguments. OCSURL is OCS's
base URL from which will be constructed it's SOAP URL. USER and PASSWD
are the credentials that will be used to authenticate into OCS. Any
other arguments will be passed to the L<SOAP::Lite> object that will
be created to talk to OCS.

=cut

sub new {
    my ($class, $url, $user, $pass, @args) = @_;

    my $uri = URI->new($url);
    $uri->path("/Apache/Ocsinventory/Interface");

    my $proxy = URI->new($url);

    my $userinfo;
    $userinfo  = $user if $user;
    $userinfo .= ':'   if $user && $pass;
    $userinfo .= $pass if $pass;
    $proxy->userinfo($userinfo) if $userinfo;

    $proxy->path("/ocsinterface");

    my $self = { soap => SOAP::Lite->uri($uri->as_string)->proxy($proxy->as_string, @args) };

    return bless $self, $class;
}

=head3 B<get_computers_V1> REQUEST-MAP

This method allows for querying inventoried computers.

The REQUEST-MAP is a key-value list of information that is used to
construct the XML request structure defined in the OCS documentation
(see link above). Any key-value pair passed to the method is appended
to the following default list:

    engine     => 'FIRST',
    asking_for => 'INVENTORY',
    checksum   => 0x01FFFF,
    wanted     => 0x000003,
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
	checksum   => 0x01FFFF,
	wanted     => 0x000003,
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

=head3 B<computer_iterator> REQUEST-MAP

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

=head3 B<prune> COMPUTER

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
your script if you intend to use this method. (May the source be with
you, Luke!)

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
	    $drive->{ORDER} =~ s@:/$@:@;
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

    if (exists $computer->{PRINTERS}) {
	$computer->{PRINTERS} = [sort {$a->{NAME} cmp $b->{NAME}} @{$computer->{PRINTERS}}];
    }

    # Of the software we only keep the name and the version
    if (exists $computer->{SOFTWARES}) {
	$computer->{SOFTWARES} = {map {($_->{NAME} => $_->{VERSION})} @{$computer->{SOFTWARES}}};
    }

    if (exists $computer->{STORAGES}) {
	$computer->{STORAGES} = [grep {$_->{TYPE} !~ /removable/i} @{$computer->{STORAGES}}];
    }

    if (exists $computer->{VIDEOS}) {
	foreach my $video (@{$computer->{VIDEOS}}) {
	    delete @{$video}{qw/RESOLUTION/};
	}
    }

    return $computer;
}

=head2 CONSTANTS

This module defines some constants to make the calling of methods
B<get_computers_V1> and B<computer_iterator> easier and more readable.

These are for their CHECKSUM parameter.

    'HARDWARE'            => 0x00001,
    'BIOS'                => 0x00002,
    'MEMORY_SLOTS'        => 0x00004,
    'SYSTEM_SLOTS'        => 0x00008,
    'REGISTRY'            => 0x00010,
    'SYSTEM_CONTROLLERS'  => 0x00020,
    'MONITORS'            => 0x00040,
    'SYSTEM_PORTS'        => 0x00080,
    'STORAGE_PERIPHERALS' => 0x00100,
    'LOGICAL_DRIVES'      => 0x00200,
    'INPUT_DEVICES'       => 0x00400,
    'MODEMS'              => 0x00800,
    'NETWORK_ADAPTERS'    => 0x01000,
    'PRINTERS'            => 0x02000,
    'SOUND_ADAPTERS'      => 0x04000,
    'VIDEO_ADAPTERS'      => 0x08000,
    'SOFTWARE'            => 0x10000,

And these are for their WANTED parameter.

    'ACOUNTINFO'          => 0x00001,
    'DICO_SOFT'           => 0x00002,

=cut

use constant {
    # CHECKSUM constants
    'HARDWARE'            => 0x00001,
    'BIOS'                => 0x00002,
    'MEMORY_SLOTS'        => 0x00004,
    'SYSTEM_SLOTS'        => 0x00008,
    'REGISTRY'            => 0x00010,
    'SYSTEM_CONTROLLERS'  => 0x00020,
    'MONITORS'            => 0x00040,
    'SYSTEM_PORTS'        => 0x00080,
    'STORAGE_PERIPHERALS' => 0x00100,
    'LOGICAL_DRIVES'      => 0x00200,
    'INPUT_DEVICES'       => 0x00400,
    'MODEMS'              => 0x00800,
    'NETWORK_ADAPTERS'    => 0x01000,
    'PRINTERS'            => 0x02000,
    'SOUND_ADAPTERS'      => 0x04000,
    'VIDEO_ADAPTERS'      => 0x08000,
    'SOFTWARE'            => 0x10000,

    # WANTED constants
    'ACOUNTINFO'          => 0x00001,
    'DICO_SOFT'           => 0x00002,
};

1; # End of OCS::Client
