use Test;
use lib 't/08-moar';
use UnipropCheck;
# Please edit UnipropCheck.pm6 to change todo settings!
sub MAIN (Str $folder?, Bool:D :$debug = False) {
    my $*DEBUG = $debug;
    my $name = $*PROGRAM.basename.subst(/".t"$/, "").trans("-" => "/");
    my ($property, $filename, $answer-column) = $name.split(':');
    $filename ~= ".txt";
    my $folder-io = $folder ?? $folder.IO !! IO::Path;
    test-file $folder-io, $filename, $property, :answer-column($answer-column);
    done-testing;
}
