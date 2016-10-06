# ABSTRACT: Comment on a commit in the audit.
package Git::Code::Review::Command::comment;
use strict;
use warnings;

use CLI::Helpers qw(
    output
    prompt
);
use File::Temp qw(tempfile);
use File::Spec;
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use POSIX qw(strftime);
use YAML;


sub opt_spec {
    return (
        ['message|m=s@',    "Use the given value as the comment message. If multiple -m options are given, their values are concatenated as separate paragraphs."],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review comment [options] <commit hash>

    DESCRIPTION

        This command allows a reviewer or author to comment on a commit and have
        that comment tracked in the audit.

    EXAMPLES

        git-code-review comment 44d3b68e

        git-code-review comment -m "Your concern is valid, but it was discussed by email with management and business has agreed to accept this risk." 44d3b68e

        git-code-review comment -m "Your concern is valid, but it was discussed by email with management and business has agreed to accept this risk." -m "Refer to email dated 2016-09-02." 44d3b68e

        git-code-review comment --message "This commit has been approved based on the agreement that this workaround will be removed next month." 44d3b68e

    OPTIONS
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my ($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    my $match = shift @$args;
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    if( !defined $match ) {
        output({color=>'red'}, "Please specify a commit hash from the source repository to comment on.");
        exit 1;
    }

    my $auditdir = gcr_dir();
    my %cfg = gcr_config();
    my $audit = gcr_repo();
    gcr_reset();

    my @list = grep { !/Locked/ } $audit->run('ls-files',"*$match*.patch");
    if( @list == 0 ) {
        output({color=>"red"}, "Unable to locate any unlocked files matching '$match'");
        exit 0;
    }
    my $pick = $list[0];
    if( @list > 1 ) {
        $pick = prompt("Matched multiple commits, which would you like to comment on? ",menu => \@list);
    }
    my $commit = gcr_commit_info($pick);

    my @content = $opt->{ message } ? map { ( "$_\n", "\n" ) } @{ $opt->{ message } } : ();
    pop @content if scalar @content;    # remove the last empty line
    if ( ! scalar @content ) {
        # let user create a comment in the editor
        my ($fh,$tmpfile) = tempfile();
        print $fh "\n"x2, map {"$_\n"}
            "# Commenting on $commit->{sha1}",
            "#  at $commit->{current_path}",
            "#  State is $commit->{state}",
            "# Lines beginning with a '#' will be skipped.",
            "# Leave all lines empty to exit without adding a comment.",
        ;
        close $fh;
        gcr_open_editor( modify => $tmpfile );
        # should have contents
        open($fh,"<", $tmpfile) or die "Tempfile($tmpfile) problems: $!";
        my $len = 0;
        my $blank = 0;
        while( <$fh> )  {
            next if /^#/;
            # Reduce blank lines to 1
            if ( /^\s*$/ ) {
                $blank++;
                next if $blank > 1;
            }
            else {
                $blank = 0;
            }
            $len += length;
            push @content, $_;
        }
        close $fh;
        eval {
            unlink $tmpfile;
        };
    }
    if ( scalar grep { /\S/ } @content ) {
        # Add the comment!
        my $comment_id = sprintf("%s-%s.txt",strftime('%F-%T',localtime),$cfg{user});
        my @comment_path = map { $_ eq 'Review' ? 'Comments' : $_; } File::Spec->splitdir( $commit->{review_path} );
        pop @comment_path if $comment_path[-1] =~ /\.patch$/;
        push @comment_path, $commit->{sha1};
        gcr_mkdir(@comment_path);

        my $repo_path = File::Spec->catfile(@comment_path,$comment_id);
        my $file_path = File::Spec->catfile($auditdir,$repo_path);
        open(my $fh,">",$file_path) or die "Cannot create comment($file_path): $!";
        print $fh $_ for @content;
        close $fh;
        $audit->run( add => $repo_path );
        my $message = gcr_commit_message($commit,{state=>"comment",message=>join('',@content)});
        $audit->run( commit => '-m', $message);
        gcr_push();
    } else {
        # allow user to abort with empty comment
        output({color=>"red"}, "Empty comment was skipped.");
    }
}

1;
