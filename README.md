# aula_r_geo

Material de aula prática de introdução ao R para geoprocessamento.

## Preparação dos dados

Os arquivos em `dados/` são gerados a partir de fontes oficiais:

- malha municipal do Rio de Janeiro via `geobr`;
- população municipal estimada via IBGE/SIDRA.

Execute antes da aula:

```sh
Rscript scripts/preparar_dados.R
```

Se a chamada ao `geobr` falhar por problema de pacote ou cache, o script tenta reinstalar/atualizar `geobr` automaticamente e roda novamente uma vez. Se a falha persistir na dependência interna de leitura, o script usa os metadados do próprio `geobr` e lê o parquet oficial com `arrow`.

## Renderização

Depois de preparar os dados, gere o HTML com:

```sh
quarto render aula_pratica.qmd
```
