#!/usr/bin/perl

use feature 'say';

use Modern::Perl;
use Getopt::Long;
use File::Slurp qw( read_file write_file prepend_file );
use Data::Dumper;

my $file;
my $verbose;
my $output_dir = ".";
my $help;

GetOptions(
    "f|file=s"       => \$file,
    "o|output_dir=s" => \$output_dir,
    "v|verbose"      => \$verbose,
    "h|help"         => \$help,
) or die("Error in command line arguments\n");

say
"export_offline_circ_log.pl --file /path/to/offlinecirc.log --output_dir /path/to/dir -v"
  and exit(1)
  if $help || !$file;

my @lines = read_file($file) or die "File not found!";

my $seen = {};
foreach my $l (@lines) {
    my @parts      = split( "\t", $l );
    my $branchcode = pop(@parts);
    chomp $branchcode;
    my $line     = join( "\t", @parts );
    my $filename = "$output_dir/$branchcode.koc";

    $seen->{$branchcode} = 1;

    say "Writing line '$line' to file $filename" if $verbose;
    write_file( $filename, { append => 1 }, "$line\n" );
}

my $header =
  "Version=1.0\tGenerator=export_offline_circ_log.pl\tGeneratorVersion=1.0";

foreach my $branchcode ( keys %$seen ) {
    my $filename = "$output_dir/$branchcode.koc";
    prepend_file( $filename, "$header\n" );
    say "Writing header to file $filename";
}
