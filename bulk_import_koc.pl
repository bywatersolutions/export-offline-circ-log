#!/usr/bin/perl

# 2023 Kyle Hall <kyle.m.hall@gmail.com>

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use File::Slurp;
use Getopt::Long;
use File::Basename;
use Data::Dumper;
use t::lib::Mocks;

use C4::Circulation
  qw( AddOfflineOperation GetOfflineOperations ProcessOfflineOperation );

my $FILE_VERSION = '1.0';

my $dir;
my $confirm = 0;
my $verbose = 0;
my $process = 0;
my $import  = 0;
GetOptions(
    "c|confirm"  => \$confirm,
    "i|import"   => \$import,
    "p|process"  => \$process,
    "d|dir=s"    => \$dir,
    "v|verbose+" => \$verbose,
) or die("Error in command line arguments\n");

unless ( $dir || $confirm || $process || $import ) {
    say "bulk_import_koc.pl -d /path/to/dirs [--confirm] [--verbose] [--process] [--import]
Import ingests files, Process converts *all* pending offline ops into actual checkins and checkouts.
Directory is assumed to be a set of subdirectories named after the branchcodes, containing nothing but .koc files.
";
    exit(1);
}

if ($import) {
    my @paths = read_dir( $dir, prefix => 1 );

    foreach my $path (@paths) {
        my ($branchcode) = fileparse($path);

        say "WORKING ON BRANCHCODE $branchcode" if $verbose;

        unless ( Koha::Libraries->find($branchcode) ) {
            say qq{BRANCHCODE "$branchcode" IS INVALID, SKIPPING.} if $verbose;
            next;
        }

        my @files = read_dir( $path, prefix => 1 );
        foreach my $file (@files) {
            say qq{PROCESSING FILE "$file"};

            my @lines = read_file($file);

            my $header_line = shift @lines;
            say "HEADER LINE: $header_line" if $verbose > 1;
            my $file_info = parse_header_line($header_line);
            say "PARSED HEADER: " . Data::Dumper::Dumper($file_info)
              if $verbose > 2;
            if ( $file_info->{'Version'} ne $FILE_VERSION ) {
                say "ERROR: FILE IS NOT KOC VERSION $FILE_VERSION, SKIPPING"
                  if $verbose;
                next;
            }

            my $userid = 0;

            foreach my $line (@lines) {
                say "LINE: $line" if $verbose > 1;
                my $command_line = parse_command_line($line);
                say "PARSED LINE: " . Data::Dumper::Dumper($command_line)
                  if $verbose > 2;
                my $timestamp =
                  $command_line->{'date'} . ' ' . $command_line->{'time'};
                my $action     = $command_line->{'command'};
                my $barcode    = $command_line->{'barcode'};
                my $cardnumber = $command_line->{'cardnumber'};
                my $amount     = $command_line->{'amount'};

                AddOfflineOperation(
                    $userid,  $branchcode, $timestamp, $action,
                    $barcode, $cardnumber, $amount
                ) unless $confirm;
            }

        }
    }
}

if ($process) {
    my $database = Koha::Database->new();
    my $schema   = $database->schema();
    my $rs       = $schema->resultset('PendingOfflineOperation')->search();

    while ( my $r = $rs->next ) {
        say "PROCESSING OFFLINE CIRC: " . $r->id;

        t::lib::Mocks::mock_userenv(
            {
                flags          => 1,
                userid         => 0,
                borrowernumber => 0,
                branch         => $r->{branchcode},
            }
        );

        my $report = ProcessOfflineOperation(
            {
                operationid => $r->operationid,
                userid      => $r->userid,
                branchcode  => $r->branchcode,
                timestamp   => $r->timestamp,
                action      => $r->action,
                barcode     => $r->barcode,
                cardnumber  => $r->cardnumber,
                amount      => $r->amount,
            }
        ) unless $confirm;

        say "REPORT: $report" if $verbose > 2;
    }
}

=head1 FUNCTIONS

=head2 parse_header_line

parses the header line from a .koc file. This is the line that
specifies things such as the file version, and the name and version of
the offline circulation tool that generated the file. See
L<http://wiki.koha-community.org/wiki/Koha_offline_circulation_file_format>
for more information.

pass in a string containing the header line (the first line from th
file).

returns a hashref containing the information from the header.

=cut

sub parse_header_line {
    my $header_line = shift;
    chomp($header_line);
    $header_line =~ s/\r//g;

    my @fields = split( /\t/, $header_line );
    say Data::Dumper::Dumper( \@fields );
    my %header_info = map { split( /=/, $_ ) } @fields;
    return \%header_info;
}

=head2 parse_command_line

=cut

sub parse_command_line {
    my $command_line = shift;
    chomp($command_line);
    $command_line =~ s/\r//g;

    my ( $timestamp, $command, @args ) = split( /\t/, $command_line );
    my ( $date,      $time,    $id )   = split( /\s/, $timestamp );

    my %command = (
        date    => $date,
        time    => $time,
        id      => $id,
        command => $command,
    );

    # set the rest of the keys using a hash slice
    my $argument_names = arguments_for_command($command);
    @command{@$argument_names} = @args;

    return \%command;

}

=head2 arguments_for_command

fetches the names of the columns (and function arguments) found in the
.koc file for a particular command name. For instance, the C<issue>
command requires a C<cardnumber> and C<barcode>. In that case this
function returns a reference to the list C<qw( cardnumber barcode )>.

parameters: the command name

returns: listref of column names.

=cut

sub arguments_for_command {
    my $command = shift;

    # define the fields for this version of the file.
    my %format = (
        issue   => [qw( cardnumber barcode )],
        return  => [qw( barcode )],
        payment => [qw( cardnumber amount )],
    );

    return $format{$command};
}

=head2 _get_borrowernumber_from_barcode

pass in a barcode
get back the borrowernumber of the patron who has it checked out.
undef if that can't be found

=cut

sub _get_borrowernumber_from_barcode {
    my $barcode = shift;

    return unless $barcode;

    my $item = Koha::Items->find( { barcode => $barcode } );
    return unless $item;

    my $issue = Koha::Checkouts->find( { itemnumber => $item->itemnumber } );
    return unless $issue;
    return $issue->borrowernumber;
}
