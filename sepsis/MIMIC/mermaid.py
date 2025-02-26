import re

def extract_tables_and_relations(sql_content):
    tables = {}
    relations = []

    # Extrair tabelas
    for match in re.finditer(r'CREATE TABLE (\w+)\.(\w+)', sql_content):
        schema, table = match.groups()
        if schema not in tables:
            tables[schema] = []
        tables[schema].append(table)

    # Extrair relações
    for line in sql_content.split('\n'):
        if 'JOIN' in line:
            matches = re.findall(r'(\w+)\.(\w+)', line)
            if len(matches) >= 2:
                source = f"{matches[0][0]}.{matches[0][1]}"
                target = f"{matches[1][0]}.{matches[1][1]}"
                relations.append((source, target))

    return tables, relations

def generate_mermaid(tables, relations):
    mermaid = "graph TD\n"

    # Criar subgraphs
    for schema, table_list in tables.items():
        mermaid += f"    subgraph {schema}\n"
        for table in table_list:
            mermaid += f"        {table}[{table}]\n"
        mermaid += "    end\n\n"

    # Adicionar relações
    for source, target in relations:
        source_table = source.split('.')[1]
        target_table = target.split('.')[1]
        mermaid += f"    {source_table} --> {target_table}\n"

    return mermaid

# Ler o arquivo SQL
with open('final-poc01.sql', 'r', encoding='utf-8') as file:
    sql_content = file.read()

# Extrair tabelas e relações
tables, relations = extract_tables_and_relations(sql_content)

# Gerar o diagrama Mermaid
mermaid_diagram = generate_mermaid(tables, relations)

# Salvar o diagrama Mermaid em um arquivo
with open('mimic_diagram.mmd', 'w') as file:
    file.write(mermaid_diagram)

print("Diagrama Mermaid gerado em 'mimic_diagram.mmd'")