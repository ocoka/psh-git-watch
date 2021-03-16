<# set this to $null if you don't have files to ignore by this script #>
$assumeUnchangedFiles = "*ettings.*json"


$gitRoot = git rev-parse --show-toplevel
if (!$?) {
  Write-Error "Not a Git repository"
  exit
}
Set-Location $gitRoot
# Later will be filled we initial commit revision
$global:base = ""

$timer = [System.Timers.Timer]::new(4000)
$timer.Start();
$planned = @{};
$gitActions = {
  Write-Host "Check GIT queue.." -NoNewline
  if ($planned.Count -gt 0) {
    Write-Host "$($planned.Count) items"
    $planned.Keys | ForEach-Object {
      git add $_
    }
    git commit -m "sync" --squash $global:base
    git pull --commit --autostash --no-rebase --no-edit
    git push origin
    $planned.Clear();
  }
  Write-Host "GIT ✔"
};
Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier GitTimer  | Out-Null
$clearAssumed = {
  if ($null -eq $assumeUnchangedFiles ) {
    return
  }
  Get-ChildItem -Recurse -File -Include $assumeUnchangedFiles | ForEach-Object {
    git update-index --no-assume-unchanged -- $_.FullName
  }

}
$markAssumed = {
  if ($null -eq $assumeUnchangedFiles ) {
    return
  }
  Get-ChildItem -Recurse -File -Include $assumeUnchangedFiles | ForEach-Object {
    git reset -- $_.FullName
    git update-index --assume-unchanged -- $_.FullName
  }
}

$initCommit = {
  Write-Output "Make initial commit"
  $message = Read-Host -Prompt "Please describe you future work in several words"
  git add -AN
  git add .
  .$markAssumed
  git commit --allow-empty -m $message
  $global:base = git rev-parse HEAD
}



$stateAskBranch = {
  $branch = Read-Host -Prompt "What branch name ?"
  git rev-parse $branch 2>$null | Out-Null
  if ($?) {
    $cont = Read-Host -Prompt "Branch already exist, continue ?"
    if ($cont.ToLower() -notlike "y*") {
      .$stateAskBranch
      return
    }
    git switch $branch
    git pull --commit --autostash --no-rebase --no-edit
    if (!$?) {
      Write-Warning "Something strange. You don't have upstream branch for current branch `"$branch`", so that can't be used."
      exit
    }
    .$initCommit
    git push origin
  }
  else {
    git switch -c $branch
    .$initCommit
    git push -u origin $branch
    if (!$?) {
      # maybe already created
      git fetch
      git branch --set-upstream-to=origin/$branch $branch
      git pull --commit --autostash --no-rebase --no-edit
      git push origin
    }
  }
}
.$stateAskBranch
$ignored = @(
  ".git"
)
function CheckNotIgnored
{
  Param([string]$Path)
  $exgit = git check-ignore $Path
  return $null -eq $exgit -and $null -eq ($ignored | Where-Object { $Path.Contains($_)})
}

Write-Output "----------------------"
Write-Output "Start to watch changes"
Write-Output "----------------------"

$watcher = [System.IO.FileSystemWatcher]::new($PWD);
$watcher.EnableRaisingEvents = $true
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = "LastWrite, FileName, Size"
Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier FileWatcher | out-null
Write-Output "Press 'q' to quit"
while($true) {
  $ev = Wait-Event
  $ev | ForEach-Object {
    if ($_.SourceIdentifier -eq "FileWatcher") {
      if (CheckNotIgnored($_.SourceEventArgs.FullPath)) {
        if (-not $planned.ContainsKey($_.SourceEventArgs.FullPath)) {
          Write-Host "Change detected on $($_.SourceEventArgs.FullPath)"
          $planned.Add($_.SourceEventArgs.FullPath, 1)
          Write-Host "File queued"
        }
      }
    }
    if ($_.SourceIdentifier -eq "GitTimer" -and $ev.Count -eq 1) {
      .$gitActions
    }
    Remove-Event -EventIdentifier $_.EventIdentifier
  }
  if ($host.ui.RawUI.KeyAvailable) {
    $key = $host.UI.RawUI.ReadKey();
    if ($null -ne $key -and $key.Character -eq 'q') {
      Write-Host "`nUnregistering events handler";
      Get-EventSubscriber | Unregister-Event
      .$clearAssumed
      break;
    }
  }
}
