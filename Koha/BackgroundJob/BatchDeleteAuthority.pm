package Koha::BackgroundJob::BatchDeleteAuthority;

use Modern::Perl;
use JSON qw( encode_json decode_json );

use Koha::BackgroundJobs;
use Koha::DateUtils qw( dt_from_string );
use C4::AuthoritiesMarc;

use base 'Koha::BackgroundJob';

sub job_type {
    return 'batch_authority_record_deletion';
}

sub process {
    my ( $self, $args ) = @_;

    my $job_type = $args->{job_type};

    my $job = Koha::BackgroundJobs->find( $args->{job_id} );

    if ( !exists $args->{job_id} || !$job || $job->status eq 'cancelled' ) {
        return;
    }

    # FIXME If the job has already been started, but started again (worker has been restart for instance)
    # Then we will start from scratch and so double delete the same records

    my $job_progress = 0;
    $job->started_on(dt_from_string)
        ->progress($job_progress)
        ->status('started')
        ->store;

    my $mmtid = $args->{mmtid};
    my @record_ids = @{ $args->{record_ids} };

    my $report = {
        total_records => scalar @record_ids,
        total_success => 0,
    };
    my @messages;
    my $schema = Koha::Database->new->schema;
    RECORD_IDS: for my $record_id ( sort { $a <=> $b } @record_ids ) {

        last if $job->get_from_storage->status eq 'cancelled';

        next unless $record_id;

        $schema->storage->txn_begin;

        my $authid = $record_id;
        eval { C4::AuthoritiesMarc::DelAuthority({ authid => $authid }) };
        if ( $@ ) {
            push @messages, {
                type => 'error',
                code => 'authority_not_deleted',
                authid => $authid,
                error => ($@ ? $@ : 0),
            };
            $schema->storage->txn_rollback;
            next;
        } else {
            push @messages, {
                type => 'success',
                code => 'authority_deleted',
                authid => $authid,
            };
            $report->{total_success}++;
            $schema->storage->txn_commit;
        }

        $job->progress( ++$job_progress )->store;
    }

    my $job_data = decode_json $job->data;
    $job_data->{messages} = \@messages;
    $job_data->{report} = $report;

    $job->ended_on(dt_from_string)
        ->data(encode_json $job_data);
    $job->status('finished') if $job->status ne 'cancelled';
    $job->store;
}

sub enqueue {
    my ( $self, $args) = @_;

    # TODO Raise exception instead
    return unless exists $args->{record_ids};

    my @record_ids = @{ $args->{record_ids} };

    $self->SUPER::enqueue({
        job_size => scalar @record_ids,
        job_args => {record_ids => \@record_ids,}
    });
}

1;