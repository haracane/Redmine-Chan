use strict;
use warnings;
use utf8;

package Redmine::Chan::API {
  my (@KEYS, @CACHES, @REGEXES);
  BEGIN {
    @KEYS = qw/ users issue_statuses trackers /;
    @CACHES = map '_'.$_, @KEYS;
    @REGEXES = map $_.'_regexp_hash', @KEYS;
  }

  use List::Util qw/ first /;
  use JSON;

  use base qw(WebService::Simple);
  use Class::Accessor::Lite (
    rw => [
      qw( api_key issue_fields member_api_key who status_commands custom_field_prefix ),
      @CACHES, @REGEXES,
    ],
  );

  __PACKAGE__->config(
    response_parser => 'JSON',
  );

  use YAML::Tiny;
  my $member_api_key_file = 'member_api_key_file.yml';
  -d $member_api_key_file || `touch $member_api_key_file`;
  my $member_api_key_yaml = YAML::Tiny->read($member_api_key_file);

  sub fetch_data {
    my $self = shift;
    my $url  = shift or return;
    my $key  = shift || $url;
    $url .= '.json' unless $url =~ /[.]json$/;
    my $data = eval {
      $self->get(
        $url => {
          key => $self->api_key,
          limit => 100, # max limit Redmine
        },
      )->parse_response;
    } or return;
    return $data->{$key};
  }

  for my $method (@KEYS) {
    no strict 'refs';
    *{__PACKAGE__."\::$method"} = sub {
      my ($self, %param) = @_;
      my $cache = '_'.$method;
      return $self->$cache if $self->$cache;
      return $self->$cache($self->fetch_data($method));
    };
    *{__PACKAGE__."\::${method}_summary"} = sub {
      my ($self, %param) = @_;
      my $data = $self->$method;
      my @summary;
      for my $item (sort {$a->{id} <=> $b->{id}} @$data) {
        push @summary, sprintf "%d : %s", $item->{id}, $item->{login} || $item->{name};
      }
      return join ' , ', @summary;
    };
  }

  sub reload {
    my $self = shift;
    my $commands = $self->status_commands || {};
    for my $method (@KEYS) {
      my $cache = '_'.$method;
      my $data = $self->fetch_data($method);
      $self->$cache($data);

      # for detect_issue
      my $regexp = $method.'_regexp_hash';
      my $hash;
      for my $item (@$data) {
          my @commands = $method eq 'issue_statuses' ? @{$commands->{$item->{id}} || []} : ();
          my $re = join '|', map { quotemeta } ($item->{login} || $item->{name}), @commands;
          $hash->{$re} = $item->{id};
      }
      $self->$regexp($hash);
    }

    $self->member_api_key($member_api_key_yaml->[0] || $self->member_api_key);
  }

  sub set_api_key {
    my ($self, $who, $key) = @_;
    $key =~ s{\s+}{}g;
    $key or return;
    $self->member_api_key->{$who} = $key;

    $member_api_key_yaml->[0] = $self->member_api_key;
    $member_api_key_yaml->write($member_api_key_file);

    return "set key $who : $key";
  }

  sub api_key_as {
    my ($self, $who) = @_;
    $self->{member_api_key}->{$who || ''} || $self->api_key;
  }

  sub issue {
    my $self = shift;
    my $issue_id = shift or return;
    my $issue = $self->fetch_data("issues/${issue_id}.json", 'issue');
    return $issue;
  }

  sub issue_detail {
    my $self = shift;
    my $issue = $self->issue(shift) or return;
    my $fiedls = $self->issue_fields || [qw/subject assigned_to status/];
    my $subject = join ' ', map {"[$_]"} grep {$_} map {
      /^\d+$/ ? $issue->{custom_fields}->[$_]->{value}
        : ref($issue->{$_}) ? $issue->{$_}->{name} : $issue->{$_}
    } @$fiedls;
    my $uri = $self->base_url->clone;
    my $authority = $uri->authority;
    $authority =~ s{^.*?\@}{}; # URLに認証が含まれてたら消す
    $uri->authority($authority);
    my @segments = ();
    for my $segment ($uri->path_segments) {
      push @segments, $segment if $segment ne "";
    }
    $uri->path_segments(@segments, "issues", $issue->{id});

    return "$uri : $subject\n";
  }

  sub detect_user_id {
    my $self = shift;
    my $msg = shift;
    my ($user_id, $user_name);
    for my $name ($msg =~ /[\w\-]{3,}/g) {
      for my $user (@{$self->users}) {
        $user->{login} eq $name or next;
        $user_id = $user->{id};
        $user_name = $name;
        last;
      }
    }
    if ($user_id) {
      $msg =~ s{>?\s*\Q$user_name\E}{};
    }
    return ($user_id, $msg);
  }

  sub detect_tracker_id {
    my $self = shift;
    my $msg = shift;
    my $hash = $self->trackers_regexp_hash;
    my $tracker_id;
    for my $key (keys %{$hash || {}}) {
      if ($msg =~ s{\b\Q$key\E\b}{}) {
        $tracker_id = $hash->{$key};
        last;
      }
    }
    return ($tracker_id, $msg);
  }

  sub detect_status_id {
    my $self = shift;
    my $msg = shift;
    my $hash = $self->issue_statuses_regexp_hash;
    my $status_id;
    for my $key (keys %{$hash || {}}) {
      if ($msg =~ s{\b($key)\b}{}) {
        $status_id = $hash->{$key};
        last;
      }
    }
    return ($status_id, $msg);
  }

  sub detect_due_date {
    my $self = shift;
    my $msg = shift;
    my $due_date;
    if ($msg =~ s|\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b||) {
      $due_date = sprintf '%04d-%02d-%02d', $1, $2, $3;
    }
    return ($due_date, $msg);
  }

  sub detect_custom_field_values {
    my $self = shift;
    my $msg = shift or return;
    my $prefix = $self->custom_field_prefix || {};
    my $custom_field_values;
    for my $id (sort keys %$prefix) {
      my $re = join '|', map { quotemeta } @{$prefix->{$id} || []};
      if ($msg =~ s{\b$re(\S+)}{}) {
        $custom_field_values->{$id} = $1;
        last;
      }
    }
    return ($custom_field_values, $msg);
  }

  sub create_issue {
    my ($self, $msg, $project_id) = @_;
    my $issue = {};
    ($msg, $issue) = $self->detect_issue($msg);
    length($msg) or return;
    if (! defined $issue->{due_date}) {
      my ($d, $m, $y) = (localtime)[3,4,5];
      $m += 1;
      $y += 1900;
      $issue->{due_date} = sprintf('%04d-%02d-%02d', $y, $m, $d);
    }

    if (! defined $issue->{assigned_to_id}) {
      if (my $user = first { $_->{login} eq $self->who } @{$self->users}) {
        $issue->{assigned_to_id} = $user->{id};
      }
    }

    $issue = {
      project_id  => $project_id,
      subject   => $msg,
      #priority_id => 7,    # 優先度MAX
      estimated_hours => 3,  # 予定工数
      description => <<"...",
* 発端
** 
* ゴール
** 
...
      %$issue,
    };

    my $res = eval { $self->post(
      'issues.json',
      Content_Type => 'application/json',
      Content => encode_json {
        issue    => $issue,
        project_id => $project_id,
        key    => $self->api_key_as($self->who),
      }
    )->parse_response };

    return $self->issue_detail($res->{issue}->{id});
  }

  sub update_issue {
    my ($self, $issue_id, $msg) = @_;
    my $issue = {};
    ($msg, $issue) = $self->detect_issue($msg);
    scalar %$issue or return;

    $self->put($issue_id, $issue);
  }

  sub detect_issue {
    my ($self, $msg) = @_;
    $msg or return;
    my ($assigned_to_id, $tracker_id, $status_id, $due_date, $custom_field_values);
    ($assigned_to_id, $msg)      = $self->detect_user_id($msg);
    ($tracker_id, $msg)          = $self->detect_tracker_id($msg);
    ($status_id, $msg)           = $self->detect_status_id($msg);
    ($due_date, $msg)            = $self->detect_due_date($msg);
    ($custom_field_values, $msg) = $self->detect_custom_field_values($msg);
    $msg =~ s{\s+$}{};
    my $issue = {};
    $issue->{assigned_to_id}      = $assigned_to_id if $assigned_to_id;
    $issue->{tracker_id}          = $tracker_id if $tracker_id;
    $issue->{status_id}           = $status_id if $status_id;
    $issue->{due_date}            = $due_date if $due_date;
    $issue->{custom_field_values} = $custom_field_values if $custom_field_values;
    return ($msg, $issue);
  }

  sub note_issue {
    my ($self, $issue_id, $note) = @_;
    $self->put($issue_id, { notes => $note });
  }

  sub put {
    my ($self, $issue_id, $issue) = @_;

    my $uri = $self->base_url->clone;
    my @segments = ();
    for my $segment ($uri->path_segments) {
      push @segments, $segment if $segment ne "";
    }
    $uri->path_segments(@segments, "issues", "${issue_id}.json");

    # XXX: WebService::Simple に put 実装されてないので LWP::UserAgent の put 叩いてる
    $self->SUPER::put(
      $uri,
      Content_Type => 'application/json',
      Content => encode_json {
        issue => $issue,
        key   => $self->api_key_as($self->who),
      },
    );
  }
}

1;
__END__

=head1 NAME

Redmine::Chan::API

=head1 SYNOPSIS

    use Redmine::Chan::API;
    my $api = Redmine::Chan::API->new;
    $api->base_url($url);
    $api->api_key($api_key);

=head1 AUTHOR

Yasuhiro Onishi  C<< <yasuhiro.onishi@gmail.com> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2012, Yasuhiro Onishi C<< <yasuhiro.onishi@gmail.com> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

