#!/usr/bin/perl

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

BEGIN {

    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

use Getopt::Long;
use Pod::Usage;
use Text::CSV_XS;
use DateTime;
use DateTime::Duration;

use C4::Context;
use C4::Letters;
use C4::Log;
use Koha::DateUtils;
use Koha::Calendar;
use Koha::Libraries;
use Koha::Script -cron;

=head1 NAME

holds_reminder.pl - prepare reminder messages to be sent to patrons with waiting holds

=head1 SYNOPSIS

holds_reminder.pl
  [ -n ][ -library <branchcode> ][ -library <branchcode> ... ]
  [ -days <number of days> ][ -csv [<filename>] ][ -itemscontent <field list> ]
  [ -email <email_type> ... ]

 Options:
   -help                          brief help message
   -man                           full documentation
   -v                             verbose
   -n                             No email will be sent
   -days          <days>          days waiting to deal with
   -lettercode   <lettercode>     predefined notice to use
   -library      <branchname>     only deal with holds from this library (repeatable : several libraries can be given)
   -holidays                      use the calendar to not count holidays as waiting days
   -mtt          <message_transport_type> type of messages to send, default is to use patrons messaging preferences for Hold filled
                                  populating this will force send even if patron has not chosen to receive hold notices
                                  email and sms will fallback to print if borrower does not have an address/phone
   -date                          Send notices as would have been sent on a specific date

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=item B<-v>

Verbose. Without this flag set, only fatal errors are reported.

=item B<-n>

Do not send any email (test-mode) . If verbose a list of notices that would have been sent to
the patrons are printed to standard out.

=item B<-days>

Optional parameter, number of days an items has been 'waiting' on hold
to send a message for. If not included a notice will be sent to all
patrons with waiting holds.

=item B<-library>

select notices for one specific library. Use the value in the
branches.branchcode table. This option can be repeated in order
to select notices for a group of libraries.

=item B<-holidays>

This option determines whether library holidays are used when calculating how
long an item has been waiting. If enabled the count will skip closed days.

=item B<-date>

use it in order to send notices on a specific date and not Now. Format: YYYY-MM-DD.

=item B<-mtt>

send a notices via a specific transport, this can be repeated to send various notices.
If omitted the patron's messaging preferences for Hold notices will be used.
If supplied the notice types will be force sent even if patron has not selected hold notices
Email and SMS will fall back to print if there is no valid info in the patron's account


=back

=head1 DESCRIPTION

This script is designed to alert patrons of waiting
holds.

=head2 Configuration

This script sends reminders to patrons with waiting holds using a notice
defined in the Tools->Notices & slips module within Koha. The lettercode
is passed into this script and, along with other options, determine the content
of the notices sent to patrons.


=head1 USAGE EXAMPLES

C<holds_reminder.pl> - With no arguments the simple help is printed

C<holds_reminder.pl -lettercode CODE > In this most basic usage all
libraries are processed individually, and notices are prepared for
all patrons with waiting holds for whom we have email addresses.
Messages for those patrons for whom we have no email
address are sent in a single attachment to the library administrator's
email address, or to the address in the KohaAdminEmailAddress system
preference.

C<holds_reminder.pl -lettercode CODE -n -csv /tmp/holds_reminder.csv> - sends no email and
populates F</tmp/holds_reminder.csv> with information about all waiting holds
items.

C<holds_reminder.pl -lettercode CODE -library MAIN -days 14> - prepare notices of
holds waiting for 2 weeks for the MAIN library.

C<holds_reminder.pl -library MAIN -days 14 -list-all> - prepare notices
of holds waiting for 2 weeks for the MAIN library and include all the
patron's waiting hold

=cut

# These variables are set by command line options.
# They are initially set to default values.
my $dbh = C4::Context->dbh();
my $help    = 0;
my $man     = 0;
my $verbose = 0;
my $nomail  = 0;
my $days    ;
my $lettercode;
my @branchcodes; # Branch(es) passed as parameter
my $use_calendar = 0;
my $date_input;
my $opt_out = 0;
my @mtts;

GetOptions(
    'help|?'         => \$help,
    'man'            => \$man,
    'v'              => \$verbose,
    'n'              => \$nomail,
    'days=s'         => \$days,
    'lettercode=s'   => \$lettercode,
    'library=s'      => \@branchcodes,
    'date=s'         => \$date_input,
    'holidays'       => \$use_calendar,
    'mtt=s'          => \@mtts
);
pod2usage(1) if $help;
pod2usage( -verbose => 2 ) if $man;

if ( !$lettercode ) {
    pod2usage({
        -exitval => 1,
        -msg => qq{\nError: You must specify a lettercode to send reminders.\n},
    });
}


cronlogaction();

# Unless a delay is specified by the user we target all waiting holds
unless (defined $days) {
    $days=0;
}

# Unless one ore more branchcodes are passed we use all the branches
if (scalar @branchcodes > 0) {
    my $branchcodes_word = scalar @branchcodes > 1 ? 'branches' : 'branch';
    $verbose and warn "$branchcodes_word @branchcodes passed on parameter\n";
}
else {
    @branchcodes = Koha::Libraries->search()->get_column('branchcode');
}

# If provided we run the report as if it had run on a specified date
my $date_to_run;
if ( $date_input ){
    eval {
        $date_to_run = dt_from_string( $date_input, 'iso' );
    };
    die "$date_input is not a valid date, aborting! Use a date in format YYYY-MM-DD."
        if $@ or not $date_to_run;
}
else {
    $date_to_run = dt_from_string();
}

# Loop through each branch
foreach my $branchcode (@branchcodes) { #BEGIN BRANCH LOOP
    # Check that this branch has the letter code specified or skip this branch
    my $letter = C4::Letters::getletter( 'reserves', $lettercode , $branchcode );
    unless ($letter) {
        $verbose and print qq|Message '$lettercode' content not found for $branchcode\n|;
        next;
    }

    # If respecting calendar get the correct waiting since date
    my $waiting_date;
    if( $use_calendar ){
        my $calendar = Koha::Calendar->new( branchcode => $branchcode, days_mode => 'Calendar' );
        my $duration = DateTime::Duration->new( days => -$days );
        $waiting_date = $calendar->addDays($date_to_run,$duration); #Add negative of days
    } else {
        $waiting_date = $date_to_run->subtract( days => $days );
    }

    # Find all the holds waiting since this date for the current branch
    my $dtf = Koha::Database->new->schema->storage->datetime_parser;
    my $waiting_since = $dtf->format_date( $waiting_date );
    my $reserves = Koha::Holds->search({
        waitingdate => {'<=' => $waiting_since },
        branchcode  => $branchcode,
    });

    $verbose and warn "No reserves found for $branchcode\n" unless $reserves->count;
    next unless $reserves->count;
    $verbose and warn $reserves->count . " reserves waiting since $waiting_since for $branchcode\n";

    # We only want to send one notice per patron per branch - this variable will hold the completed borrowers
    my %done;

    # If passed message transports we force use those, otherwise we will use the patrons preferences
    # for the 'Hold_Filled' notice
    my $sending_params = @mtts ? { message_transports => \@mtts } : { message_name => "Hold_Filled" };


    while ( my $reserve = $reserves->next ) {

        my $patron = $reserve->borrower;
        # Skip if we already dealt with this borrower
        next if ( $done{$patron->borrowernumber} );
        $verbose and print "  borrower " . $patron->surname . ", " . $patron->firstname . " has holds triggering notice.\n";

        # Setup the notice information
        my $letter_params = {
            module          => 'reserves',
            letter_code     => $lettercode,
            borrowernumber  => $patron->borrowernumber,
            branchcode      => $branchcode,
            tables          => {
                 borrowers  => $patron->borrowernumber,
                 branches   => $reserve->branchcode,
                 reserves   => $reserve->unblessed
            },
        };
        $sending_params->{letter_params} = $letter_params;
        $sending_params->{test_mode} = $nomail;
        my $result_text = $nomail ? "would have been sent" : "was sent";
        # queue_notice queues the notices, falling back to print for email or SMS, and ignores phone (they are handled by Itiva)
        my $result = $patron->queue_notice( $sending_params );
        $verbose and print "   borrower " . $patron->surname . ", " . $patron->firstname . " $result_text notices via: @{$result->{sent}}\n" if defined $result->{sent};
        $verbose and print "   borrower " . $patron->surname . ", " . $patron->firstname . " $result_text print fallback for: @{$result->{fallback}}\n" if defined $result->{fallback};
        # Mark this borrower as completed
        $done{$patron->borrowernumber} = 1;
    }


} #END BRANCH LOOP