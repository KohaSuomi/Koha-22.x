package Koha::AuthorisedValue;

# Copyright ByWater Solutions 2014
#
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

use Koha::Caches;
use Koha::Database;

use base qw(Koha::Object Koha::Object::Limit::Library);

=head1 NAME

Koha::AuthorisedValue - Koha Authorised value Object class

=head1 API

=head2 Class methods

=cut

=head3 store

AuthorisedValue specific store to ensure relevant caches are flushed on change

=cut

sub store {
    my ($self) = @_;

    my $flush = 0;

    if ( !$self->in_storage ) {
        $flush = 1;
    }
    else {
        my $self_from_storage = $self->get_from_storage;
        $flush = 1 if ( $self_from_storage->lib ne $self->lib );
        $flush = 1 if ( $self_from_storage->lib_opac ne $self->lib_opac );
    }

    $self = $self->SUPER::store;

    if ($flush) {
        my $cache = Koha::Caches->get_instance();
        my $key = "AVDescriptions-".$self->category;
        $cache->clear_from_cache($key);
    }

    return $self;
}

=head3 opac_description

my $description = $av->opac_description();

=cut

sub opac_description {
    my ( $self, $value ) = @_;

    return $self->lib_opac() || $self->lib();
}

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'AuthorisedValue';
}

=head3 _library_limits

=cut

sub _library_limits {
    return {
        class   => 'AuthorisedValuesBranch',
        id      => 'av_id',
        library => 'branchcode'
    };
}

=head1 AUTHOR

Kyle M Hall <kyle@bywatersolutions.com>

=cut

1;
