package Stash::REST;
use strict;
use 5.008_005;
our $VERSION = '0.032';

use warnings;
use utf8;
use URI;
use HTTP::Request::Common qw(GET POST DELETE HEAD);
use Carp qw/confess/;

use Moo;
use namespace::clean;

use Class::Trigger;

has 'do_request' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a CodeRef" unless ref $_[0] eq 'CODE'},
    required => 1
);

has 'decode_response' => (
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

sub _capture_args {
    my ($self, @params) = @_;
    my ($uri, $data, %conf);

    confess 'rest_post invalid number of params' if @params < 1;

    $uri = shift @params;
    confess 'rest_post invalid uri param' if ref $uri ne '' && ref $uri ne 'ARRAY';

    $uri = join '/', @$uri if ref $uri eq 'ARRAY';

    if (scalar @params % 2 == 0){
        %conf = @params;
        $data = exists $conf{data} ? $conf{data} : [];
    }else{
        $data = pop @params;
        %conf = @params;
    }

    confess 'rest_post param $data invalid' unless ref $data eq 'ARRAY';


    return ($self, $uri, $data, %conf);
}

sub rest_put {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->call_trigger('before_rest_put', \$url, \$data, \%conf);
    $self->_rest_request(
        $url,
        code => ( exists $conf{is_fail} ? 400 : 202 ),
        %conf,
        method => 'PUT',
        $data
    );
}

sub rest_head {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->call_trigger('before_rest_head', \$url, \$data, \%conf);
    $self->_rest_request(
        $url,
        code => 200,
        %conf,
        method => 'HEAD',
        $data
    );
}

sub rest_delete {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->call_trigger('before_rest_delete', \$url, \$data, \%conf);
    $self->_rest_request(
        $url,
        code => 204,
        %conf,
        method => 'DELETE',
        $data
    );
}

sub rest_get {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->call_trigger('before_rest_get', \$url, \$data, \%conf);
    $self->_rest_request(
        $url,
        code => 200,
        %conf,
        method => 'GET',
        $data
    );
}

sub rest_post {
    my ($self, $url, $data, %conf) = &_capture_args(@_);
    $self->call_trigger('before_rest_post', \$url, \$data, \%conf);

    $self->_rest_request(
        $url,
        %conf,
        method => 'POST',
        $data
    );
}

sub _rest_request {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    my $is_fail = exists $conf{is_fail} && $conf{is_fail};

    my $code = $conf{code};
    $code ||= $is_fail ? 400 : 201;
    $conf{code} = $code;

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

    $self->call_trigger('process_request', \$req, \%conf);

    $req->method( $conf{method} ) if exists $conf{method};

    my $res = eval{$self->do_request()->($req)};
    confess "request died: $@" if $@;

    $self->call_trigger('process_response', \$req, \$res, \%conf);

    #is( $res->code, $code, $name . ' status code is ' . $code );
    confess 'response expected fail and it is successed' if $is_fail && $res->is_success;
    confess 'response expected success and it is failed' if !$is_fail && !$res->is_success;

    confess 'response code [',$res->code,'] diverge expected [',$code,']' if $code != $res->code;

    $self->call_trigger('process_response_success', \$req, \$res, \%conf);

    return '' if $code == 204;
    return $res if exists $conf{method} && $conf{method} eq 'HEAD';

    my $obj = eval { $self->decode_response()->( $res ) };
    confess("decode_response failed: $@") if $@;

    $self->call_trigger('response_decoded', \$req, \$res, \$obj, \%conf);

    if ($stashkey) {
        $self->stash->{$stashkey} = $obj;

        $self->stash( $stashkey . '.prepare_request' => $conf{prepare_request} ) if exists $conf{prepare_request};

        if ( $code == 201 ) {
            $self->stash( $stashkey . '.id' => $obj->{id} ) if ref $obj eq 'HASH' && exists $obj->{id};

            my $item_url = $res->header('Location');

            if ($item_url){
                $self->stash->{$stashkey . '.url'} = $item_url ;

                $self->rest_reload($stashkey);

                $self->call_trigger('item_loaded', $stashkey, \%conf);
            }else{
                confess 'requests with response code 201 should contain header Location';
            }

            $self->call_trigger('stash_added', $stashkey, \%conf);
        }
    }

    if ( $stashkey && exists $conf{list} ) {

        $self->stash( $stashkey . '.list-url' => $url );

        $self->rest_reload_list($stashkey);

        $self->call_trigger('list_loaded', $stashkey, \%conf);

    }

    return $obj;
}


sub rest_reload {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;
    $conf{code} = $code;


    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.url' };

    confess "can't stash $stashkey.url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;

    confess 'prepare_request must be a coderef'
        if $prepare_request && ref $prepare_request ne 'CODE';

    my $req = POST $item_url, @headers, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;

    $self->call_trigger('process_request', \$req, \%conf);
    my $res = $self->do_request()->($req);

    $self->call_trigger('process_response', \$req, \$res, \%conf);

    confess 'request code diverge expected' if $code != $res->code;

    $self->call_trigger('process_response_success', \$req, \$res, \%conf);

    my $obj;
    if ( $res->code == 200 ) {
        my $obj = eval { $self->decode_response()->( $res ) };
        confess("decode_response failed: $@") if $@;

        $self->call_trigger('response_decoded', \$req, \$res, \$obj, \%conf);

        $self->stash( $stashkey . '.get' => $obj );
    }
    elsif ( $res->code == 404 ) {

        $self->call_trigger('stash_removed', $stashkey, \%conf);

        # $self->stash->{ $stashkey . '.get' };
        delete $self->stash->{ $stashkey . '.id' };
        delete $self->stash->{ $stashkey . '.url' };
        delete $self->stash->{ $stashkey };

    }
    else {
        confess 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}


sub rest_reload_list {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;
    $conf{code} = $code;

    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.list-url' };

    confess "can't stash $stashkey.list-url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;
    confess 'prepare_request must be a coderef'
        if $prepare_request && ref $prepare_request ne 'CODE';

    my $req = POST $item_url, @headers, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;

    $self->call_trigger('process_request', \$req, \%conf);

    my $res = $self->do_request()->($req);

    $self->call_trigger('process_response', \$req, \$res, \%conf);

    confess 'request code diverge expected' if $code != $res->code;

    $self->call_trigger('process_response_success', \$req, \$res, \%conf);

    my $obj;
    if ( $res->code == 200 ) {
        my $obj = eval { $self->decode_response()->( $res ) };
        confess("decode_response failed: $@") if $@;

        $self->call_trigger('response_decoded', \$req, \$res, \$obj, \%conf);

        $self->stash( $stashkey . '.list' => $obj );
    }
    else {
        confess 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}

sub stash_ctx {
    my ( $self, $staname, $sub ) = @_;

    $self->call_trigger('before_stash_ctx', $staname);

    my @ret = $sub->( $self->stash->{$staname} );

    $self->call_trigger('after_stash_ctx', $staname, \@ret);
    return @ret;
}


1;

__END__

=encoding utf-8

=head1 NAME

Stash::REST - Add Requests into stash. Then, Extends with Class::Trigger!

=head1 SYNOPSIS

    use Stash::REST;
    use JSON;

    $obj = Stash::REST->new(
        do_request => sub {
            my $req = shift;

            # in case of testings

            my ($res, $c) = ctx_request($req);
            return $res;

            # in case of using LWP
            $req->uri( 'http://your-api.com' );
            return LWP::UserAgent->new->request($req);

        },
        decode_response => sub {
            my $res = shift;
            return decode_json($res->content);
        }
    );

    # you can write/read stash anytime
    $obj->stash('foo') # returns undef

    $obj->stash->{'foo'} = 3;

    $obj->stash('foo') # returns 3


    $obj->rest_post(
        '/zuzus',
        name  => 'add zuzu', # you can send fields for your custom on extensions.
        list  => 1,
        stash => 'easyname',
        prepare_request => sub {
            is(ref $_[0], 'HTTP::Request', 'HTTP::Request recived on prepare_request');
            $run++;
        },
        [ name => 'foo', ]
    );
    is($run, '2', '2 executions of prepare_request');

    $obj->rest_put(
        $obj->stash('easyname.url'),
        name => 'update zuzu',
        [ new_option => 'new value' ]
    );

    $obj->rest_reload('easyname');

    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;

            is( $me->{name}, 'AAAAAAAAA', 'name updated!' );
        }
    );

    # reload expecting a different code.
    $obj->rest_reload( 'easyname', code => 404 );

    $obj->rest_reload_list('easyname');

    # HEAD return $res instead of parsed response
    my $res = $obj->rest_head(
        $obj->stash('easyname.url'),
    );
    is($res->headers->header('foo'), '1', 'header is present');

    $obj->stash->{'easyname'} # parsed response for POST /zuzus
    $obj->stash->{'easyname.id'} # HashRef->{id} if exists, from POST response.
    $obj->stash->{'easyname.get'} # parsed response of GET /zuzus/1 (from Location)
    $obj->stash->{'easyname.url'} # 'zuzus/1'

    if list => 1 is passed:
    $obj->stash->{'easyname.list'} # parsed response for GET '/zuzus'
    $obj->stash->{'easyname.list-url'} # '/zuzus'


    # this
    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;
        }
    );

    # equivalent to
    my $me = $c->stash->{'easyname.get'};

    # can be useful for testing/context isolation
    $obj->stash_ctx(
        'easyname.list',
        sub {
            my ($me) = @_;

            ok( $me = delete $me->{zuzus}, 'zuzu list exists' );

            is( @$me, 1, '1 zuzu' );

            is( $me->[0]{name}, 'foo', 'listing ok' );
        }
    );


    $obj->rest_delete( $obj->stash('easyname.url') );

=head1 DESCRIPTION

Stash::REST helps you use HTTP::Request::Common to create requests and put responses into a stash for further user.

The main objective is to encapsulate the most used HTTP methods and expected response codes for future
extensions and analysis by other modules, using the callbacks L<Class::Trigger>.


=head1 METHODS

=head2 new

    Stash::REST->new(
        do_request => sub {
            ...
        },
        decode_response => sub {
            ...
        }
    );

=head2 rest_get

Same as:

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'GET',
        $data
    );

=head2 rest_put

Same as:

    $self->rest_post(
        $url,
        code => ( exists $conf{is_fail} ? 400 : 202 ),
        %conf,
        method => 'PUT',
        $data
    );

=head2 rest_head

Same as:

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'HEAD',
        $data
    );

=head2 rest_delete

Same as:

    $self->rest_post(
        $url,
        code => 204,
        %conf,
        method => 'DELETE',
        $data
    );

=head2 _capture_args

This is a private method. It parse and validate params for rest_post and above methods.

    my ($self, $url, $data, %conf) = &_capture_args(@_);

    So, @_ must have a items like this:

        $self, # (required) self object
        $url,  # (required) a string. If ARRAY $url will return a join '/', @$url
        %conf, # (optional) configuration hash (AKA list). Odd number will cause problems.
        $data  # (optional) ArrayRef, send on body as application/x-www-form-urlencoded data

    # $data can be also sent as $conf{data} = []

=head2 rest_post


This is the main method, and accept some options on %conf.

=head3 Defaults options

=head4 is_fail => 0,

This test if $res->is_success must be true or false. Die with confess if not archived.

=head4 code => is_fail ? 400 : 201,

This test if $res->code equivalent to expected. Die with confess if not archived.


=head3 Optional options:

=head4 stash => 'foobar'

Load parsed response on C< $obj->stash->{foobar} > and some others fields

C< $obj->stash->{foobar.id} > if response code is 201 and parsed response contains ->{id}
C< $obj->stash->{foobar.url} > if response code is 201 and header contains Location (confess if missed)


=head4 list => 1,

If true, Location header will be looked and a GET on Location will occur and parsed data will be stashed on
C< $obj->stash->{foobar.list} > and list-url on C< $obj->stash->{foobar.list-url} >

=head2 stash_ctx

    $obj->stash_ctx(
        'easyname.get',
        sub {
            my ($me) = @_;
        }
    );


    Get an stash-name and run a CodeRef with the stash as first @_

=head2 rest_reload

Reload the GET easyname.url and put on stash.

    $obj->rest_reload( 'easyname' );

    # reload expecting a different code.
    $obj->rest_reload( 'easyname', code => 404 );

When response is 404, some stash{easyname} is cleared.

=head2 rest_reload_list

Reload the GET easyname.list-url and put on stash.

    $obj->rest_reload_list('easyname');

This response code must be 200 OK.

=head2 stash

Copy from old Catalyst.pm, but $t->stash('foo') = $t->stash->{'foo'}

Returns a hashref to the stash, which may be used to store data and pass
it between components during a test. You can also set hash keys by
passing arguments. Unlike catalyst, it's never cleared, so, it lasts until object this destroy.

    $t->stash->{foo} = $bar;
    $t->stash( { moose => 'majestic', qux => 0 } );
    $t->stash( bar => 1, gorch => 2 ); # equivalent to passing a hashref

=head1 Tests Coverage

I'm always trying to improve those numbers.
Improve branch number is a very time-consuming task. There is a room for test all checking and defaults on tests.


    ---------------------------- ------ ------ ------ ------ ------ ------ ------
    File                           stmt   bran   cond    sub    pod   time  total
    ---------------------------- ------ ------ ------ ------ ------ ------ ------
    blib/lib/Stash/REST.pm         94.9   73.1   81.4  100.0    0.0  100.0   84.6
    Total                          94.9   73.1   81.4  100.0    0.0  100.0   84.6
    ---------------------------- ------ ------ ------ ------ ------ ------ ------

=head1 Class::Trigger names

Updated @ Stash-REST 0.03

    $ grep  '$self->call_trigger' lib/Stash/REST.pm  | perl -ne '$_ =~ s/^\s+//; $_ =~ s/self-/self0_03-/; print' | sort | uniq

    Trigger / variables:

    $self0_03->call_trigger('after_stash_ctx', $staname, \@ret);
    $self0_03->call_trigger('before_rest_delete', \$url, \$data, \%conf);
    $self0_03->call_trigger('before_rest_get', \$url, \$data, \%conf);
    $self0_03->call_trigger('before_rest_head', \$url, \$data, \%conf);
    $self0_03->call_trigger('before_rest_post', \$url, \$data, \%conf);
    $self0_03->call_trigger('before_rest_put', \$url, \$data, \%conf);
    $self0_03->call_trigger('before_stash_ctx', $staname);
    $self0_03->call_trigger('item_loaded', $stashkey, \%conf);
    $self0_03->call_trigger('list_loaded', $stashkey, \%conf);
    $self0_03->call_trigger('process_request', \$req, \%conf);
    $self0_03->call_trigger('process_response', \$req, \$res, \%conf);
    $self0_03->call_trigger('response_decoded', \$req, \$res, \$obj, \%conf);
    $self0_03->call_trigger('stash_added', $stashkey, \%conf);
    $self0_03->call_trigger('stash_removed', $stashkey, \%conf);


Updated @ Stash-REST 0.02

    $ grep  '$self->call_trigger' lib/Stash/REST.pm  | perl -ne '$_ =~ s/^\s+//; $_ =~ s/self-/self0_02-/; print' | sort | uniq

    Trigger / variables:

    $self_0_02->call_trigger('before_rest_delete', \$url, \$data, \%conf);
    $self_0_02->call_trigger('before_rest_get', \$url, \$data, \%conf);
    $self_0_02->call_trigger('before_rest_head', \$url, \$data, \%conf);
    $self_0_02->call_trigger('before_rest_post', \$url, \$data, \%conf);
    $self_0_02->call_trigger('before_rest_put', \$url, \$data, \%conf);
    $self_0_02->call_trigger('item_loaded', $stashkey);
    $self_0_02->call_trigger('list_loaded', $stashkey);
    $self_0_02->call_trigger('process_request', \$req);
    $self_0_02->call_trigger('process_response', \$req, \$res);
    $self_0_02->call_trigger('response_decoded', \$req, \$res, \$obj);
    $self_0_02->call_trigger('stash_added', $stashkey);
    $self_0_02->call_trigger('stash_removed', $stashkey);


=head1 AUTHOR

Renato CRON E<lt>rentocron@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2015- Renato CRON

Thanks to http://eokoe.com

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Stash::REST::TestMore>, L<Class::Trigger>

=cut
