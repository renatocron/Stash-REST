package Stash::REST;
use strict;
use 5.008_005;
our $VERSION = '0.01';

use Moo;
use warnings;
use utf8;
use URI;
use JSON;
use HTTP::Request::Common qw(GET POST DELETE HEAD);
use Carp;

has 'do_request' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a CodeRef" unless ref $_[0] eq 'CODE'},
    required => 1
);
has 'stash' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a HashRef" unless ref $_[0] eq 'HASH'},
    default => sub { {} }
);

has 'fixed_headers' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a ArrayRef" unless ref $_[0] eq 'ARRAY'},
    default => sub { [] }
);

around 'stash' => sub {
    my $orig  = shift;
    my $c     = shift;
    my $stash = $orig->($c);

    if (@_) {
        return $stash->{ $_[0] } if ( @_ == 1 && ref $_[0] eq '' );

        my $new_stash = @_ > 1 ? {@_} : $_[0];
        die('stash takes a hash or hashref') unless ref $new_stash;
        foreach my $key ( keys %$new_stash ) {
            $stash->{$key} = $new_stash->{$key};
        }
    }

    return $stash;
};

sub rest_put {
    my $self = shift;
    my $url  = shift;
    my $data = pop || [];
    my %conf = @_;

    $self->rest_post(
        $url,
        code => ( exists $conf{is_fail} ? 400 : 202 ),
        %conf,
        method => 'PUT',
        $data
    );
}

sub rest_head {
    my $self = shift;
    my $url  = shift;
    my $data = pop || [];
    my %conf = @_;

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'HEAD',
        $data
    );
}

sub rest_delete {
    my $self = shift;
    my $url  = shift;
    my $data = pop || [];
    my %conf = @_;

    $self->rest_post(
        $url,
        code => 204,
        %conf,
        method => 'DELETE',
        $data
    );
}

sub rest_get {
    my $self = shift;
    my $url  = shift;
    my $data = pop || [];
    my %conf = @_;

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'GET',
        $data
    );
}

sub rest_post {
    my $self = shift;
    my $url  = shift;
    my $data = pop || [];
    my %conf = @_;

    $url = join '/', @$url if ref $url eq 'ARRAY';

    my $is_fail = exists $conf{is_fail} && $conf{is_fail};

    my $code = $conf{code};
    $code ||= $is_fail ? 400 : 201;



    my $stashkey = exists $conf{stash} ? $conf{stash} : undef;

    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );

    my $req;

    if ( !exists $conf{files} ) {
        $req = POST $url, $data, @headers;
    }
    else {
        $conf{files}{$_} = [ $conf{files}{$_} ] for keys %{ $conf{files} };

        $req = POST $url,
          @headers,
          'Content-Type' => 'form-data',
          Content => [ @$data, %{ $conf{files} } ];
    }

    $req->method( $conf{method} ) if exists $conf{method};

    my $res = eval{$self->do_request()->($req)};
    croak "request died: $@" if $@;

    #is( $res->code, $code, $name . ' status code is ' . $code );
    croak 'request success diverge expected' if ($is_fail && $res->is_success) || (!$res->is_success);
    croak 'request code diverge expected' if $code != $res->code;

    return '' if $code == 204;

    my $obj = eval { decode_json( $res->content ) };
    #fail($@) if $@;

    if ($stashkey) {
        $self->stash->{$stashkey} = $obj;

        $self->stash( $stashkey . '.prepare_request' => $conf{prepare_request} ) if exists $conf{prepare_request};

        if ( $code == 201 ) {
            $self->stash( $stashkey . '.id' => $obj->{id} ) if exists $obj->{id};

            my $item_url = $res->header('Location');

            if ($item_url){
                $self->stash->{$stashkey . '.url'} = $item_url ;

                $self->rest_reload($stashkey);
            }else{
                croak 'requests with response code 201 should contain header Location';
            }
        }
    }

    if ( $stashkey && exists $conf{list} ) {

        $self->stash( $stashkey . '.list-url' => $url );

        $self->rest_reload_list($stashkey);

    }

    return $obj;
}


sub rest_reload {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;


    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.url' };

    croak "can't stash $stashkey.url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      && ref $self->stash->{ $stashkey . '.prepare_request' } eq 'CODE'
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;

    my $req = POST $item_url, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;

    my $res = $self->do_request()->($req);

    croak 'request code diverge expected' if $code != $res->code;

    my $obj;
    if ( $res->code == 200 ) {
        $obj = eval { decode_json( $res->content ) };

        $self->stash( $stashkey . '.get' => $obj );
    }
    elsif ( $res->code == 404 ) {

        #ok( !$res->is_success, 'GET ' . $item_url . ' does not exists' );
        #is( $res->code, 404, 'GET ' . $item_url . ' status code is 404' );

        delete $self->stash->{ $stashkey . '.get' };
        delete $self->stash->{ $stashkey . '.id' };
        delete $self->stash->{ $stashkey . '.url' };
        delete $self->stash->{ $stashkey };

    }
    else {
        croak 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}


sub rest_reload_list {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;

    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.list-url' };

    croak "can't stash $stashkey.list-url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      && ref $self->stash->{ $stashkey . '.prepare_request' } eq 'CODE'
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;

    my $req = POST $item_url, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;


    my $res = $self->do_request()->($req);

    croak 'request code diverge expected' if $code != $res->code;

    my $obj;
    if ( $res->code == 200 ) {
        $obj = eval { decode_json( $res->content ) };
        $self->stash( $stashkey . '.list' => $obj );
    }
    elsif ( $res->code == 404 ) {

        delete $self->stash->{ $stashkey . '.list' };
        delete $self->stash->{ $stashkey . '.list-url' };
        delete $self->stash->{ $stashkey };

    }
    else {
        croak 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}

sub stash_ctx {
    my ( $self, $staname, $sub ) = @_;

    $sub->( $self->stash->{$staname} );
}


1;

__END__

=encoding utf-8

=head1 NAME

Stash::REST - Blah blah blah

=head1 SYNOPSIS

  use Stash::REST;

=head1 DESCRIPTION

Stash::REST is


=head1 METHODS


=head2 $t->stash

Copy from old Catalyst.pm, but $t->stash('foo') = $t->stash->{'foo'}

Returns a hashref to the stash, which may be used to store data and pass
it between components during a test. You can also set hash keys by
passing arguments. Unlike catalyst, it's never cleared, so, it lasts until object this destroy.

    $t->stash->{foo} = $bar;
    $t->stash( { moose => 'majestic', qux => 0 } );
    $t->stash( bar => 1, gorch => 2 ); # equivalent to passing a hashref


=head1 AUTHOR

Renato CRON E<lt>rentocron@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2015- Renato CRON

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
