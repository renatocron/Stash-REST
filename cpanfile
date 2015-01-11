requires 'perl', '5.008005';

requires 'Moo';
requires 'URI';
requires 'JSON', '2.34';
requires 'HTTP::Request::Common';
requires 'Carp';

on test => sub {

    requires 'Test::More', '0.96';

    requires 'HTTP::Response';
    requires 'Test::Fake::HTTPD';
    requires 'LWP::UserAgent';
    requires 'URL::Encode', '0.03';
};
