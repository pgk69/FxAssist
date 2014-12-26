eval 'exec perl -wS $0 ${1+"$@"}'
  if 0;

#-------------------------------------------------------------------------------------------------
# Letzte Aenderung:     $Date: $
#                       $Revision: $
#                       $Author: $
#
# Aufgabe:		- Automatisiertes Login, Abfrage und Auswertung von Contents
#
#-------------------------------------------------------------------------------------------------

use v5.10;
use strict;
use vars qw($VERSION $SVN);

use constant SVN_ID => '($Id: $)

$Author: $ 

$Revision: $ 
$Date: $ 
';

# Extraktion der Versionsinfo aus der SVN Revision
($VERSION = SVN_ID) =~ s/^(.*\$Revision: )([0-9]*)(.*)$/1.0 R$2/ms;
$SVN = $VERSION . ' ' . SVN_ID;

$| = 1;

use FindBin qw($Bin $Script $RealBin $RealScript);
use lib $Bin . "/lib";
use lib $Bin . "/lib/FXASSIST";

#
# Module
#
use CmdLine;
use Trace;
use Configuration;

use Schedule::Cron;

use diagnostics;

use FXASSIST;
# use FXASSIST::Modul1;
# use FXASSIST::Modul2;

use Fcntl;

#
# Variablendefinition
#

#
# Objektdefinition
#

# Option-Objekt: Liest und speichert die Kommandozeilenparameter
$VERSION = CmdLine->new()->version($VERSION);

# Trace-Objekt: Liest und speichert die Meldungstexte; gibt Tracemeldungen aus
$VERSION = Trace->new()->version($VERSION);

# Config-Objekt: Liest und speichert den Inhalt der Initialisierungsdatei
$VERSION = Configuration->new()->version($VERSION);

# Kopie des Fehlerkanals erstellen zur gelegentlichen Abschaltung
no warnings;
sysopen(MYERR, "&STDERR", O_WRONLY);
use warnings;

#
#################################################################
## main
##################################################################
#
my $prg;
eval {$prg = FXASSIST->new()};
if ($@) {
  Trace->Exit(0, 1, 0x0ffff, Configuration->config('Prg', 'Name'), $VERSION);
}
$VERSION = $prg->version($VERSION);

# Die Abfrage und entsprechende Aktionen werden in einer Endlosschleife ausgeführt.
# Falls Reentranz ueber das Lockfile unterbunden wird, ist es dennoch sinnvoll 
# FxAssist in die crontab eintrutragen, falls es mal zu einem Programmabsturz kommt
while (1) {
  $prg->action();
}

Trace->Exit(0, 1, 0x00002, Configuration->config('Prg', 'Name'), $VERSION);

exit 1;
