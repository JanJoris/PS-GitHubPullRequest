﻿#requires -Version 3

<#

    Author: Jan De Dobbeleer
    Purpose: Streamline my GitHub Pull Request flow

#>

$global:GitHubPullRequestSettings = New-Object -TypeName PSObject -Property @{
  GitHubApiKey = $null
  BaseBranch   = 'master'
  Remote       = 'origin'
}

$settings = $global:GitHubPullRequestSettings

function Get-WebReponse
{
  param(
    $data
  )

  $result = $null
  try
  {
    $result = Invoke-RestMethod @data
    return New-Object PSObject -Property @{
      Success = $true
      Body    = $result
    }
  }
  catch
  {
    return Get-Failure
  }
}

function Get-Failure
{
  $message = ''
  try
  {
    $result = $_.Exception.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader -ArgumentList ($result)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $response = $reader.ReadToEnd()
    $body = ConvertFrom-Json $response
    $message = $body.errors[0].message
  }
  catch
  {
    $message = 'Failed to execute Web Request'
  }
  Write-Blank
  Write-Host "Error: $message" -ForegroundColor Red
  Write-Blank
  return New-Object PSObject -Property @{
    Success = $false
    Body    = $message
  }
}

function Get-PullRequests
{
  param(
    $repositoryInfo
  )

  $prParams = @{
    Uri         = "https://api.github.com/repos/$($repositoryInfo.User)/$($repositoryInfo.Repository)/pulls"
    Method      = 'GET'
    Headers     = @{
      Authorization = 'Basic ' + [Convert]::ToBase64String(
      [Text.Encoding]::ASCII.GetBytes($settings.GitHubApiKey + ':x-oauth-basic'))
    }
    ContentType = 'application/json'
  }

  $result = Get-WebReponse $prParams
  return $result
}

function Write-Blank
{
  Write-Host ''
}

function Show-Choices
{
  param(
    [array]
    $pullRequests,
    [string]
    $me
  )
  $i = 1
  Write-Blank
  Write-Host "Hi, $me. Please select a pull request or exit"
  Write-Blank
  foreach($pullRequest in $pullRequests)
  {
    Write-Host "${i}: $($pullRequest.Title)" -NoNewline
    Write-Host " ($($pullRequest.user.login))" -ForegroundColor Yellow
    $i++
  }
  Write-Host "${i}: Exit"
  Write-Blank
  $result = Read-Host 'Selection'
  return $result
}

function Select-Pullrequest
{
  param(
    [array]
    $pullRequests,
    [string]
    $me
  )
  $result = Show-Choices -pullRequests $pullRequests -me $me
  [int]$choice = $null
  while (!([int32]::TryParse($result , [ref]$choice )) -or $choice -lt 1 -or $choice -gt ($pullRequests.length + 1))
  {
    $result = Read-Host 'Please select a correct value'
  }
  if ($choice -gt ($result.length + 1))
  {
    Write-Blank
    Write-Host 'Goodbye!'
    return
  }
  return $pullRequests[$choice - 1]
}

function Get-GitRepositoryInfo
{
  $currentBranch = git.exe rev-parse --abbrev-ref HEAD
  $base = git.exe remote get-url $settings.Remote
  $result = New-Object PSObject -Property @{
    Repository    = ($base.Split('/') | Select-Object -Last 1).Replace('.git', '')
    User          = ($base.Split('/') | Select-Object -First 1).Replace('git@github.com:', '')
    Me            = git.exe config user.name
    CurrentBranch = $currentBranch
  }
  return $result
}

function Test-NoGitRepository
{
  $status = (Invoke-Expression -Command 'Get-GitStatus')
  return $status -eq $null
}

function Test-PreRequisites
{
  param(
    [boolean]
    $cleanDirectoryRequired = $false
  )
  if (Test-NoGitRepository)
  {
    Write-Blank
    Write-Host 'This is not a Git repository'
    Write-Blank
    return $false
  }

  if ($settings.GitHubApiKey -eq $null)
  {
    Write-Blank
    Write-Host 'Please add your GitHub API key to the settings first'
    Write-Blank
    return $false
  }

  if ($cleanDirectoryRequired)
  {
    $status = Get-VCSStatus
    $localChanges = ($status.HasIndex -or $status.HasUntracked -or $status.HasWorking)
    $localChanges = $localChanges -or (($status.Untracked -gt 0) -or ($status.Added -gt 0) -or ($status.Modified -gt 0) -or ($status.Deleted -gt 0) -or ($status.Renamed -gt 0))
    return !$localChanges
  }

  return $true
}

function Get-PullRequest
{
  $repositoryInfo = Get-GitRepositoryInfo
  $result = Get-PullRequests -repositoryInfo $repositoryInfo
  if (!($result.Success))
  {
    return
  }
  if ($result.Body.count -eq 0)
  {
    Write-Blank
    Write-Host 'There are no open pull-requests for this repository'
    Write-Blank
    return
  }
  $selectedPullRequest = Select-Pullrequest -pullRequests $result.body -me $repositoryInfo.Me
  if ($selectedPullRequest -eq $null)
  {
    Write-Blank
    return
  }
  Write-Blank
  Write-Host "Fetching $($settings.Remote)"
  git.exe fetch $settings.Remote
  return $selectedPullRequest
}

function Read-PullRequest
{
  if (!(Test-PreRequisites))
  {
    return
  }
  $selectedPullRequest = Get-PullRequest
  if ($selectedPullRequest -eq $null)
  {
    return
  }
  Write-Host 'Creating the diff'
  Write-Blank
  git.exe difftool -d -w "$($settings.Remote)/$($selectedPullRequest.base.ref)" "$($settings.Remote)/$($selectedPullRequest.head.ref)"
}

function Set-Assignee
{
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $assignee,
    [Parameter(Mandatory = $true)]
    [string]
    $issueLink
  )

  $data = @{
    assignee = $assignee
  }

  $prParams = @{
    Uri         = $issueLink
    Method      = 'PATCH'
    Headers     = @{
      Authorization = 'Basic ' + [Convert]::ToBase64String(
      [Text.Encoding]::ASCII.GetBytes($settings.GitHubApiKey + ':x-oauth-basic'))
    }
    ContentType = 'application/json'
    Body        = (ConvertTo-Json $data -Compress)
  }

  $result = Get-WebReponse $prParams
  return $result
}

function New-Pullrequest
{
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $title,
    [string]
    $head,
    [string]
    $base,
    [string]
    $body,
    [string]
    $assignee
  )

  if (!(Test-PreRequisites))
  {
    return
  }

  $repositoryInfo = Get-GitRepositoryInfo

  $upstream = git.exe rev-parse --abbrev-ref --symbolic-full-name '@{u}'
  if ($upstream -eq $null)
  {
    git.exe push --set-upstream $settings.Remote $repositoryInfo.CurrentBranch
  }

  $data = @{
    title = $title
    head  = if ($head -eq '')
    {
      $repositoryInfo.CurrentBranch
    }
    else
    {
      $head
    }
    base  = if ($base -eq '')
    {
      $settings.BaseBranch
    }
    else
    {
      $base
    }
    body  = $body
  }

  $prParams = @{
    Uri         = "https://api.github.com/repos/$($repositoryInfo.User)/$($repositoryInfo.Repository)/pulls"
    Method      = 'POST'
    Headers     = @{
      Authorization = 'Basic ' + [Convert]::ToBase64String(
      [Text.Encoding]::ASCII.GetBytes($settings.GitHubApiKey + ':x-oauth-basic'))
    }
    ContentType = 'application/json'
    Body        = (ConvertTo-Json $data -Compress)
  }

  $result = Get-WebReponse $prParams

  if (!($result.Success))
  {
    return
  }

  if (!($assignee -eq ''))
  {
      $assigneeResult = Set-Assignee -assignee $assignee -issueLink $result.body.issue_url
      Write-Host $assigneeResult
  }

  Write-Blank
  Write-Host 'Successfully created pull request'
  Write-Blank
  if ($assigneeResult.Success)
  {
    Write-Host "Assignee:      $assignee"
  }
  Write-Host "Commits:       $($result.Body.commits)"
  Write-Host "Additions:     $($result.Body.additions)"
  Write-Host "Deletions:     $($result.Body.deletions)"
  Write-Host "Changed files: $($result.Body.changed_files)"
  Write-Blank
  Write-Host "You can visit the pull request at the following URL: $($result.Body.url)"
  Write-Blank
}

function Invoke-MergeLogic
{
  param(
    [Parameter(Mandatory = $true)]
    [object]
    $pullRequest
  )
  Write-Host "Merging $($settings.Remote)/$($selectedPullRequest.head.ref) into $($selectedPullRequest.base.ref) using fast forward"
  git.exe checkout $pullRequest.base.ref
  git.exe pull
  git.exe merge "$($settings.Remote)/$($pullRequest.head.ref)" --ff-only
  git.exe push
  git.exe push $settings.Remote --delete $pullRequest.head.ref
}

function Close-PullRequest
{
  if (!(Test-PreRequisites -cleanDirectoryRequired $true))
  {
    Write-Blank
    Write-Host 'Please stash or commit your local changes before continuing'
    Write-Blank
    return
  }
  $selectedPullRequest = Get-PullRequest
  if ($selectedPullRequest -eq $null)
  {
    return
  }
  Invoke-MergeLogic -pullRequest $selectedPullRequest
}

Set-Alias rpr -Value Read-PullRequest -Description 'Review a Github pull request'
Set-Alias npr -Value New-PullRequest -Description 'Create a Github pull request'
Set-Alias cpr -Value Close-PullRequest -Description 'Close a Github pull request'
