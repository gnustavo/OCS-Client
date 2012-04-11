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

=cut

# http://wiki.ocsinventory-ng.org/index.php/Developers:Web_services

sub new {
    my ($class, $url, $user, $pass) = @_;

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
		->proxy($proxy_uri->as_string() . "/ocsinterface\n"),
    };

    return bless $self, $class;
}

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

# This function returns a closure that you can use to fetch the
# computers one by one until there is no more. It's usefull because
# the server usually has a limit to the maximum number of computers
# that get_computers_V1 can return at once.
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
my %fields = (
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

# Prune the computer description by simplifying some data structures
# and by deleting some information.
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

	delete @myinfo{'Atividade', 'UA Username'};

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

1;
