#!/usr/bin/perl

# form.cgi - script for uploading files with metadata stored as JSON

# Copyright (c) 2020 Thomas Kremer

# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.

# accept zero or more files and multiple properties from a client, according to a spec stored in "$0.configs/" and selected via parameter "cfg".
# spec = { fields : [{name : "name", value : "", label : "", type : "file"|"text"|..., title : "", values : [[option_id,text,tooltip],...], },...], rootdir : "/", filename : "%{project}/%{type}-%{name}.json", overwrite_ok : 1, mkdir : 1, dirlisting : "recursive", dirname : "%{project}", exec : [ "make", "-C", "%{project}" ] }

# external dependencies:
#  libjson-perl, libcgi-pm-perl

use strict;
use warnings;

use IO::Handle;
use Fcntl qw(:mode O_WRONLY O_CREAT O_EXCL);
use POSIX qw(floor strftime);
#use File::Copy qw(move);
use CGI qw(-utf8 escapeHTML);
use JSON;
use File::Spec;
use File::Basename;

my $script_filename = File::Spec->rel2abs(__FILE__);
my $script_dir = dirname($script_filename); # "/.../test/cgi-bin"
my $base_dir = dirname($script_dir);        # "/.../test"
# we're putting the configs in cgi-bin, because it is the only place, where
# bozohttpd and nginx won't publish them. Naming them .ht-* does nothing
# for both.
my $cfgfile_template = "%s.configs/%s.json"; # % $script_filename, $cfgname

$CGI::POST_MAX = 200<<20; # 200MB

# This fails *so* hard (see at the end of this file):
#BEGIN {open(STDERR,">","/dev/pts/146"); }

my $json = JSON->new->relaxed->utf8->pretty->canonical;

sub store_json {
  my ($fname,$value,$overwrite_mode) = @_;
  my $data = $json->encode($value);
  if (-e $fname && $overwrite_mode ne "overwrite") {
    die "file already exists: \"$fname\"";
  }
  open(my $f,">",$fname) or die "cannot open \"$fname\" for writing: $!";
  print $f $data;
  close($f);
}

sub load_json {
  my ($fname) = @_;
  open(my $f,"<",$fname) or die "cannot open \"$fname\" for reading: $!";
  local $/ = undef;
  my $data = <$f>;
  close($f);
  return $json->decode($data);
}

sub template_fill {
  my ($template,$data) = @_;
  die "need a hashref" unless ref $data eq "HASH";
  $template =~ s<%(?:%|\{([^}]++)\})><
        !defined $1 ? "%" : ($$data{$1}//"");
      >ges;
  return $template;
}

# Policy: $cfg is html-trusted. labels are html-fragments.
sub make_form {
  my ($cfg,$selflink,$msg) = @_;
  $msg //= "";
  $selflink = escapeHTML($selflink);
  my $title = escapeHTML($cfg->{title}//"Upload");
  my $sitetemplate = $cfg->{sitetemplate}//<<EOTEMPL;
<html><head><title>$title</title></head>
<body>
  %{msg}
  %{formheader}
    <h1><a href="%{selflink}" style="text-decoration: none; color:black;">$title</a></h1>
    <table border="0">
      %{fields}
      <tr><td colspan="2" style="text-align: center;">%{send}</td></tr>
    </table>
  %{formfooter}
</body></html>
EOTEMPL
  my $fieldtemplate = $cfg->{fieldtemplate}//<<EOTEMPL;
    <tr><td>%{label}</td><td>%{input}</td></tr>
EOTEMPL
  my $templdata = {
    msg => $msg,
    selflink => $selflink,
    formheader => qq(<form method="POST" action="$selflink" enctype="multipart/form-data">),
    formfooter => q(</form>),
    send => q(<input name="send" type="submit" value="Send" />),
  };
  my $fields = "";
  for my $field (@{$cfg->{fields}//[]}) {
    my $content = "";
    my $tag = "input";
    if (($field->{type}//"") eq "select") {
      my $options;
      for (@{$field->{values}}) {
        my @spec = map escapeHTML($_), @$_;
        my $args = ($field->{value}//"") eq $$_[0] ?
          q( selected="selected") : "";
        $args .= qq( title="$spec[2]") if defined $spec[2];
        $options .= qq(<option value="$spec[0]"$args>$spec[1]</option>\n);
      }
      $tag = "select";
      $content = $options;
    }
    my $args;
    for my $arg (qw(name title),$tag eq "input" ? qw(type value) : ()) {
      my $val = $$field{$arg};
      $val = "text" if $arg eq "type" && !defined $val;
      $args .= " $arg=\"".escapeHTML($val)."\"" if defined $val;
    }
    my $label = $$field{label}//escapeHTML($$field{name});
    @$templdata{qw(label input)} = (
      qq(<label for="$$field{name}">$label</label>),
      qq(<$tag id="$$field{name}"$args )
       .($tag eq "input" ? "/>":">".$content."</$tag>")
    );
    $fields .= template_fill($fieldtemplate,$templdata);
    delete(@$templdata{qw(input label)});
  }

  $templdata->{fields} = $fields;
  return template_fill($sitetemplate,$templdata);
}

sub error_out {
  print "Status: 403\nContent-Type: text/plain\n\nError\n";
  print "You probably mistyped the URL.\n";
  #print $_,"\n" for @_;
  exit 0;
}

# my $destdir = "upload/";

sub urlescape {
  my $s = shift;
  $s =~ s/([^a-zA-Z0-9\/!\[\]{}~^,.;_-])/ sprintf "%%%02x", ord($1)/ges;
  return $s;
}

sub sanitize_filename {
  my $fname = shift;
  $fname =~ s/^.*\///;
  #$fname =~ s/[^a-zA-Z0-9 !"$%&()=?\[\]{}@~^+*'#<>|,.;:_-]//gs;
  # we want to be restrictive about filenames, because they might be downloaded from a legacy operating system.
  $fname =~ s/[^a-zA-Z0-9 !$%&()=\[\]{}@~^+'#,.;_-]/_/gs;
  # protects against "..", but we don't want "." and just more dots are bad on some legacy OSes, too.
  $fname = "_" x length($fname) if $fname =~ /^\.+$/;
  return $fname;
}

sub lock_new_file {
  # make sure the filename is unique and safe from race conditions.
  my $base = shift;
  $base =~ s/(\.[^.]+)$//;
  my $ext = $1//"";
  my $name = $base.$ext;
  my $i = 0;
  my $f;
  while (!sysopen ($f,$name,O_WRONLY|O_CREAT|O_EXCL)) {
    $i++;
    $name = $base."-$i".$ext;
  }
  close($f);
  return $name;
}

sub store_file {
  my ($handle,$filename,$p_len) = @_;
  my $buffer = "";
  my $res;
  $$p_len = 0;
  open(my $f, ">", $filename) or die "cannot open $filename for writing: $!";
  while ($res = sysread($handle,$buffer,1<<20)) {
    print $f $buffer or die "cannot write to $filename: $!";
    $$p_len += $res;
    if (length($buffer) != $res) {
      die "wtf!";
    }
  }
  if (!defined($res)) {
    die "read error on handle for file $filename: $!";
  }
  close($f) or die "error while closing $filename: $!";
  return 1;
}

sub filemode2hr {
  my $mode = shift;
  my $acl = printf "%012b", $mode & 07777;
    # we hardcode S_IMODE(x) == (x & 07777) here for good reasons.
  $acl =~ y/01/\0\xff/;
  $acl = ("$acl" & "tssrwxrwxrwx") | (~"$acl" & "------------");
  # ignore suid/sticky. TODO: do we need them in any way?
  $acl = substr($acl,3);
  my $type = { S_IFREG, "-", S_IFDIR, "d", S_IFLNK, "l", S_IFBLK, "b", S_IFCHR, "c", S_IFIFO, "p", S_IFSOCK, "s" }->{S_IFMT($mode)};
  $type //= "?";
  return $type.$acl;
}

sub num2hr {
  my $num = shift;
  # This formula is actually not required to be in any form exact. It just
  # defines the point, where the next unit is used.
  #my $i = $num == 0 ? 0 : log($num*10)/log(1000);
  my $i = $num == 0 ? 0 : floor(log(abs($num)*2)/log(1024));
  $i = -6 if $i < -6;
  $i = 5 if $i > 5;
  #my $prefix = (qw(a f p n u m),"",qw(k M G T P))[$i+6];
  #$num *= 1000**(-$i);
  my $prefix = (qw(ai fi pi ni ui mi),"",qw(ki Mi Gi Ti Pi))[$i+6];
  $num *= 1024**(-$i);
  return sprintf "%.3g%s",$num,$prefix;
}

sub time2hr {
  my $time = shift;
  my $timestamp = strftime "%Y-%m-%d-%H:%M:%S", gmtime($time);
  return $timestamp;
}

my $dirlisting_defaulttemplates = {
  page => qq(<html><head><meta http-equiv="content-type: text/html; charset=UTF-8"><title>%{dirname}</title></head><body><h1>%{dirname}/</h1>\n%{entries}</body></html>\n),
  file => qq(<p>%{modeHR} %{sizeHR} %{mtimeISO} <a href="%{filename}">%{filename}</a></p>\n),
  dir => qq(<p>%{modeHR} %{sizeHR} %{mtimeISO} <a href="%{filename}/">%{filename}/</a></p>\n),
};

sub create_dirlisting {
  my ($dir,$recursive,$templates) = @_;
  $templates //= $dirlisting_defaulttemplates;
  my @entries;
  if ($recursive) {
    open(my $f, "-|", "find", ($dir =~ s{^-}{./-}r),
                            qw(-mindepth 1 -printf %P\0))
      or die "cannot find: $!";
    local $/="\0";
    @entries = <$f>;
    close($f);
  } else {
    opendir(my $f, $dir) or die "cannot read dir \"$dir\": $!";
    @entries = readdir($f);
    closedir($f);
  }
  my $prefix = $dir;
  $prefix .= "/" unless $prefix =~ m{/$};
  my $templdata = { prefix => escapeHTML($prefix), dir => escapeHTML($dir),
                    dirname => escapeHTML(basename($dir)) };
  for (@entries) {
    #$_ = [$_,[stat($prefix.$_)]];
    my @stat = stat($prefix.$_);
    my $isdir = S_ISDIR($stat[2]);
    @$templdata{qw(filename dirslash mode modeHR size sizeMiB sizeHR mtime mtimeISO ctime ctimeISO)} =
    (escapeHTML($_), $isdir ? "/" : "", sprintf("%04o",S_IMODE($stat[2])), filemode2hr($stat[2]), $stat[7], $stat[7]>>20, num2hr($stat[7])."B", $stat[9], time2hr($stat[9]), $stat[10], time2iso($stat[10]));
    my $templ = $templates->{$isdir ? "dir" : "file"};
    $_ = template_fill($templ,$templdata);
  }
  delete @$templdata{qw(filename dirslash mode modeHR size sizeMiB sizeHR mtime mtimeISO ctime ctimeISO)};
  $templdata->{entries} = join("",@entries);
  my $content = template_fill($templates->{page},$templdata);
  
  open (my $f, ">", $prefix."index.html") or die "cannot create index: $!";
  print $f $content;
  close($f);
}

# FIXED: some devices send multiple files with the same name.
sub cgi_process_request {
  my $q = shift;
  chdir($base_dir) or die "cannot chdir: $!";
  my $meth = $q->request_method//"";
  my $cfgname = sanitize_filename($q->url_param("cfg"));
  # for now strict policy: .$name.json in current directory.
  my $cfg_file = sprintf $cfgfile_template, $script_filename, $cfgname;
  #my $cfg_file = ".".$cfgname.".json";
  if (! -f $cfg_file) {
    $cfgname = "default";
    $cfg_file = sprintf $cfgfile_template, $script_filename, $cfgname;
  }
  # if $cfgname =~ m{[\0-\x1f/\x7f-\xff]} || ! -f $cfgname.".json";
  my $selflink = $q->script_name."?cfg=".urlescape($cfgname);
  my $cfg = load_json($cfg_file);
  # dies if config not found.
  my $fields = $cfg->{fields}//[];
  die "no fields" unless @$fields;

  my $msg = "";
  #$msg = `pwd`;
  if ($meth eq "POST") {
    my @cleanup;
    eval {
      my (%data,@files);
      # collect json data.
      for (@$fields) {
        my ($name,$type) = @$_{qw(name type)};
        $type //= "text";
        my $value = $q->param($name);
        if (!defined $value) {
          die "incomplete post (field $name is missing)";
        }
        #utf8::decode($value);
        $data{$name} = $value;
        if ($type eq "file") {
          my $handle = $q->upload($name);
          push @files, [$name,$handle];
          die "file missing for field \"$name\"" unless defined $handle;
        }
      }
      # determine destination filenames
      my %templdata;
      for (keys %data) {
        $templdata{$_} = sanitize_filename($data{$_});
      }
      $templdata{cfg} = $cfgname;

      # DONE: destdir handling
      # FIXED: use template engine here.
      my $fname = $cfg->{filename} // '%{file}';
      $fname = template_fill($fname,\%templdata);
      $fname = "noname" if $fname eq "";
      
      my $dirname = dirname($fname);
      
      if (!-d $dirname) {
        if ($cfg->{mkdir} && ! -e $dirname) {
          mkdir $dirname;
          push @cleanup, $dirname;
          die "could not mkdir \"$dirname\"" unless -d $dirname;
        } else {
          die "mkdir feature is disabled or \"$dirname\" is a non-directory.";
        }
      }
      #$fname = $destdir.$fname;
      $fname = lock_new_file($fname);
      $templdata{".file"} = $fname;
      $templdata{".basename"} = basename($fname);

      push @cleanup, $fname;
      my $dname = $fname.".d";
      mkdir $dname;
      push @cleanup, $dname;
      my $dname_rel = basename($dname);
         #$dname =~ s{^.*/}{}rs;
       # filename => "%{project}/%{type}-%{name}.json

      for (@files) {
        my ($name,$handle) = @$_;
        my $clientfname = $data{$name};
        my $ext = $clientfname =~ m{\.([^/.])$} ? sanitize_filename($1) : "";
           #sanitize_filename($clientfname =~ s/^.*\.//rs);
        my $target = $dname."/".$name.".".$ext;
        $data{$name} = $dname_rel."/".$name.".".$ext;
        my $len;
        push @cleanup, $target;
        store_file($handle,$target,\$len);
        $msg .= escapeHTML("File $dname_rel/$name.$ext: $len bytes")."<br/>\n";
      }
      store_json($fname,\%data,"overwrite");
      $msg .= escapeHTML("File ".basename($fname)." uploaded successfully.")."<br/>\n";
      my $link = $cfg->{link};
      if (defined $link) {
        $link = template_fill($link,\%templdata);
        # FIXME: urlencode
        $msg .= escapeHTML("<a href=\"$link\">See here</a>")."<br/>\n";
      }
      if ($cfg->{dirlisting}) {
        my $rec = ($cfg->{dirlisting} eq "recursive");
        my $templates = $cfg->{dirlisting_templates}; # or undef.
        my $dir = $dirname;
        if (defined $cfg->{dirname}) {
          $dir = template_fill($cfg->{dirname},\%templdata);
        }
        create_dirlisting($dir,$rec,$templates);
      }
      if ($cfg->{exec}) {
        die unless ref $cfg->{exec} eq "ARRAY";
        my @args = @{$cfg->{exec}};
        my $cmd = shift @args;
        for (@args) {
          $_ = template_fill($_,\%templdata);
        }
        # TODO: harden before enabling:
        #system($cmd,@args);
      }
    };
    if ($@) {
      while (@cleanup) {
        my $file = pop @cleanup;
        if (-f $file) {
          unlink $file;
        } elsif (-d $file) {
          rmdir $file;
        }
      }
      $msg .= "<span style=\"background-color:#ffaaaa\">File ".
               "could not be uploaded. Error: ".
               escapeHTML($@).".</span><br/>\n";
    }
    $msg = "<p style=\"background-color:#ddffdd;\">$msg</p>";
  }
  my $response = make_form($cfg,$selflink,$msg);
  utf8::encode($response);
  print "Status: 200\n", #; # optional
        "Content-Type: text/html; charset=UTF-8\n",
        "\n",$response;
}

my $q = CGI->new(); #\&hook);

#  hook is useless, as it does not give access to the field name.
# sub hook {
#   my ($filename,$buffer,$bytes_read,$data) = @_;
#   $_ //= "undef" for ($filename,$bytes_read);
#   print STDERR "<$filename> <$bytes_read>\n";
# }

eval {
  cgi_process_request($q);
};
if ($@) {
  error_out($@);
}

exit 0;


# This has to be the very last line in the file.
# The reason is, that bozohttpd closes stderr for perl, then
# perl opens *this* file using the first free FD, that is *stderr*,
# then reads in chunks of 8192 bytes, executing any BEGIN blocks, before
# finishing reading the file. Thus, if we have this at the beginning of the
# file, we're re-opening our own source file descriptor for writing elsewhere
# and perl complains about an unexpected end of file.
#BEGIN { open(STDERR,">","/dev/pts/146"); }
