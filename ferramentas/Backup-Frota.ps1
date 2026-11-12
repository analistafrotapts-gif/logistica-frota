param(
    [string]$Conexao = '',
    [switch]$ValidarSomente,
    [switch]$SemPausa
)

$ErrorActionPreference = 'Stop'
$projetoEsperado = 'fixvhizwcztmvmpykovr'

function Ler-ConexaoSegura([string]$Texto) {
    $uriBanco = $null
    if (-not [Uri]::TryCreate($Texto.Trim(), [UriKind]::Absolute, [ref]$uriBanco) -or $uriBanco.Scheme -notin @('postgres', 'postgresql')) {
        throw 'Cole a URI PostgreSQL do botao Connect, sem substituir [YOUR-PASSWORD].'
    }
    $partesUsuario = $uriBanco.UserInfo -split ':', 2
    $usuarioBanco = [Uri]::UnescapeDataString($partesUsuario[0])
    if ($partesUsuario.Count -gt 1) {
        $senhaNaUri = [Uri]::UnescapeDataString($partesUsuario[1])
        if ($senhaNaUri -and $senhaNaUri -notmatch '^\[YOUR[-_](DATABASE[-_])?PASSWORD\]$') {
            throw 'Nao coloque a senha na URI. Mantenha [YOUR-PASSWORD]; a senha sera pedida separadamente.'
        }
    }
    $direta = $uriBanco.Host -eq "db.$projetoEsperado.supabase.co" -and $usuarioBanco -eq 'postgres'
    $pooler = $uriBanco.Host -match '^aws-\d+-sa-east-1\.pooler\.supabase\.com$' -and $usuarioBanco -eq "postgres.$projetoEsperado"
    if (-not ($direta -or $pooler)) { throw 'A conexao nao identifica o projeto logistica-frota esperado. Nao foi feito acesso ao banco.' }
    $portaBanco = if ($uriBanco.Port -eq -1) { 5432 } else { $uriBanco.Port }
    if ($portaBanco -ne 5432 -or $uriBanco.AbsolutePath -ne '/postgres') { throw 'Use Direct connection ou Session pooler, porta 5432, banco postgres. Nao use Transaction pooler.' }
    return [pscustomobject]@{ HostBanco = $uriBanco.Host; PortaBanco = $portaBanco; UsuarioBanco = $usuarioBanco; Banco = 'postgres'; Projeto = $projetoEsperado }
}

$senhaSegura = $null
$ponteiroSenha = [IntPtr]::Zero
$variaveisAnteriores = @{}
$chavesAmbiente = @('PGPASSWORD', 'PGSSLMODE', 'PGCONNECT_TIMEOUT', 'PGOPTIONS')
$codigoFinal = 0
try {
    if (-not $Conexao) {
        Write-Host 'BACKUP PAU BRASIL - somente leitura do banco de producao' -ForegroundColor Cyan
        Write-Host 'No Supabase: projeto logistica-frota > Connect > Session pooler > URI.'
        Write-Host 'Cole a URI com [YOUR-PASSWORD], sem inserir a senha nela.'
        $Conexao = Read-Host 'URI sem senha'
    }
    $dadosConexao = Ler-ConexaoSegura $Conexao
    $Conexao = $null
    if ($ValidarSomente) { $dadosConexao | ConvertTo-Json -Compress; exit 0 }

    $pastaClientes = Join-Path $env:USERPROFILE '.codex/tools/postgresql-17/pgsql/bin'
    $pgDump = Join-Path $pastaClientes 'pg_dump.exe'
    $pgDumpAll = Join-Path $pastaClientes 'pg_dumpall.exe'
    $pgRestore = Join-Path $pastaClientes 'pg_restore.exe'
    $psql = Join-Path $pastaClientes 'psql.exe'
    foreach ($cliente in @($pgDump, $pgDumpAll, $pgRestore, $psql)) {
        if (-not (Test-Path -LiteralPath $cliente -PathType Leaf)) { throw 'Cliente PostgreSQL portatil nao encontrado. Avise ao assistente; nao instale outro servidor.' }
    }
    $versaoCliente = & $pgDump --version
    if ($LASTEXITCODE -ne 0 -or $versaoCliente -notmatch 'PostgreSQL\) 17\.') { throw 'Cliente PostgreSQL 17 necessario.' }

    $senhaSegura = Read-Host 'Senha do BANCO (nao e a senha de login do portal; caracteres ficam ocultos)' -AsSecureString
    if ($senhaSegura.Length -eq 0) { throw 'Senha nao informada. Nenhum backup foi gerado.' }
    foreach ($chaveAmbiente in $chavesAmbiente) { $variaveisAnteriores[$chaveAmbiente] = [Environment]::GetEnvironmentVariable($chaveAmbiente, 'Process') }
    $ponteiroSenha = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($senhaSegura)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ponteiroSenha)
    $env:PGSSLMODE = 'require'
    $env:PGCONNECT_TIMEOUT = '15'
    # Mesmo um comando acidental de escrita falha nesta conexao.
    $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=0'
    $argumentosConexao = @('--host', $dadosConexao.HostBanco, '--port', '5432', '--username', $dadosConexao.UsuarioBanco, '--no-password')
    $argumentosBanco = $argumentosConexao + @('--dbname', 'postgres')

    Write-Host 'Verificando a conexao por consulta somente leitura...'
    $consulta = "select json_build_object('banco',current_database(),'versao',current_setting('server_version_num'),'notas',(select count(*) from public.frota_gestao_lancamentos),'os',(select count(*) from public.frota_gestao_lancamento_os),'lotes',(select count(*) from public.frota_gestao_lancamento_lotes))::text;"
    $baselineTexto = & $psql @argumentosBanco --no-psqlrc --set ON_ERROR_STOP=1 --tuples-only --no-align --command $consulta
    if ($LASTEXITCODE -ne 0) { throw 'Falha na conexao. Nenhum backup foi confirmado. Nao redefina a senha de producao; avise ao assistente.' }
    $baseline = ($baselineTexto -join '') | ConvertFrom-Json
    if ($baseline.banco -ne 'postgres' -or [int]$baseline.versao -lt 170000 -or [int]$baseline.versao -ge 180000) { throw 'Versao ou banco inesperado. Backup interrompido.' }

    $raizBackups = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'PauBrasil/Backups/logistica-frota'))
    $pastaBackup = [IO.Path]::GetFullPath((Join-Path $raizBackups ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))))
    if (-not $pastaBackup.StartsWith($raizBackups + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destino de backup fora da pasta prevista.' }
    [IO.Directory]::CreateDirectory($pastaBackup) | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $sistema = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($principal in @($identidade, $sistema)) {
        $regra = New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($regra)
    }
    Set-Acl -LiteralPath $pastaBackup -AclObject $acl

    $parcial = Join-Path $pastaBackup 'banco.parcial'
    $arquivoDump = Join-Path $pastaBackup 'banco.dump'
    $arquivoRoles = Join-Path $pastaBackup 'roles-sem-senhas.sql'
    Write-Host 'Exportando estrutura e dados. Nenhuma tabela sera alterada...'
    & $pgDump @argumentosBanco --format=custom --lock-wait-timeout=10s --file $parcial
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $parcial)) { throw 'pg_dump nao concluiu. O arquivo parcial NAO e um backup valido. Avise ao assistente.' }
    Move-Item -LiteralPath $parcial -Destination $arquivoDump
    & $pgDumpAll @argumentosConexao --database=postgres --roles-only --no-role-passwords --file $arquivoRoles
    if ($LASTEXITCODE -ne 0) { throw 'O arquivo do banco foi gerado, mas a exportacao de roles falhou. Recuperacao ainda nao confirmada.' }
    $indice = & $pgRestore --list $arquivoDump
    if ($LASTEXITCODE -ne 0 -or -not $indice) { throw 'O arquivo nao passou na leitura do indice pg_restore. Nao iniciar migracoes.' }
    $indice | Set-Content -LiteralPath (Join-Path $pastaBackup 'indice-arquivo.txt') -Encoding UTF8
    $manifesto = [ordered]@{
        projeto = $projetoEsperado
        gerado_em_utc = [DateTime]::UtcNow.ToString('o')
        cliente = $versaoCliente
        baseline = $baseline
        arquivo = 'banco.dump'
        sha256 = (Get-FileHash -LiteralPath $arquivoDump -Algorithm SHA256).Hash
        roles_arquivo = 'roles-sem-senhas.sql'
        roles_sha256 = (Get-FileHash -LiteralPath $arquivoRoles -Algorithm SHA256).Hash
        indice_lido = $true
        restauracao_testada = $false
        observacoes = 'Backup do banco; nao inclui arquivos fisicos do Storage nem variaveis da Vercel. Ler indice nao comprova restauracao. Nao restaurar sobre producao para testar.'
    }
    $manifesto | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $pastaBackup 'manifesto.json') -Encoding UTF8
    Write-Host 'ARQUIVO DE BACKUP GERADO E INDICE LIDO.' -ForegroundColor Green
    Write-Host 'A restauracao ainda precisa ser verificada pelo assistente; nao execute SQLs agora.'
    Write-Host "Pasta do backup: $pastaBackup"
    Write-Host 'O arquivo contem dados reais. Nao envie para GitHub, chat ou pastas publicas.'
} catch {
    $codigoFinal = 1
    Write-Host ('NAO CONCLUIDO: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    foreach ($chaveAmbiente in $variaveisAnteriores.Keys) { [Environment]::SetEnvironmentVariable($chaveAmbiente, $variaveisAnteriores[$chaveAmbiente], 'Process') }
    if ($ponteiroSenha -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ponteiroSenha) }
    if ($senhaSegura) { $senhaSegura.Dispose() }
    if (-not $SemPausa -and -not $ValidarSomente) { [void](Read-Host 'Pressione Enter para fechar e informe o resultado ao assistente') }
}
exit $codigoFinal
