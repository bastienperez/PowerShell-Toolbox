function Extract-HTMLTable {
    param(
        [Parameter(Mandatory)]
        [String] $URL,

        [Parameter(Mandatory = $false)]
        [int] $TableNumber,

        # Either we know the table number, otherwise we extract all tables
        [Parameter(Mandatory = $false)]
        [switch] $AllTables,

        [Parameter(Mandatory = $false)]
        [boolean] $LocalFile
    
    )

    [System.Collections.Generic.List[PSObject]]$tablesArray = @()

    if ($LocalFile) {
        $html = New-Object -ComObject 'HTMLFile'
        $source = Get-Content -Path $URL -Raw
        $html.IHTMLDocument2_write($source)

        # html does not have ParseHTML because it already an HTMLDocumentClass
        # Cast in array in case of only one element
        $tables = @($html.getElementsByTagName('TABLE'))
    }
    else {
        $WebRequest = Invoke-WebRequest $URL -UseBasicParsing

        # Cast in array in case of only one element
        $tables = @($WebRequest.ParsedHtml.getElementsByTagName('TABLE'))
    }

    ## Extract the tables out of the web request
    if ($TableNumber) {
        #$table = $tables[$TableNumber]
        # Cast in array because only one element
        $tables = @($tables[$TableNumber])
    }

    ## Go through all of the rows in the table
    $tableNumber = 0
    foreach ($table in $tables) {
        $titles = @()
        $rows = @($table.Rows)

        $tableNumber++

        foreach ($row in $rows) {
            $cells = @($row.Cells)

            ## If we've found a table header, remember its titles
            if ($cells[0].tagName -eq 'TH') {
                $titles = @($cells | ForEach-Object { ('' + $_.InnerText).Trim() })
                continue
            }

            ## If we haven't found any table headers, make up names "P1", "P2", etc.
            if (-not $titles) {
                $titles = @(1..($cells.Count + 2) | ForEach-Object { "P$_" })
            }

            ## Now go through the cells in the the row. For each, try to find the
            ## title that represents that column and create a hashtable mapping those
            ## titles to content
            $resultObject = [Ordered] @{
                "TableNumber" = $tableNumber
            }

            for ($counter = 0; $counter -lt $cells.Count; $counter++) {
                $title = $titles[$counter]
                if (-not $title) { continue }  
                $resultObject[$title] = ('' + $cells[$counter].InnerText).Trim()
            }

            ## And finally cast that hashtable to a PSCustomObject and add to $array
            $tablesArray.Add([PSCustomObject] $resultObject)
        }
    }

    return $tablesArray
}