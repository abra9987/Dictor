import Foundation

// Встроенный набор написаний.
//
// Модель слышит технические названия правильно, но пишет их как обычные
// слова: «postgres», «msql», «sql», «windows» — всё это найдено в живом
// архиве диктовок. Здесь меняется только форма записи, латиница на
// латиницу: смысл текста не трогается, поэтому набор безопасно держать
// включённым.
//
// Чего здесь нет и не должно быть:
//
// • Замен «кириллица → латиница». «Код», «баг», «сервер», «юзер» — это
//   русские слова, а не ошибки распознавания. Программа, которая
//   переписывает их английскими, портит текст, а не чинит.
// • Слов, у которых есть обычное значение: go, rust, ruby, dart, swift,
//   pandas. «I have to go» не должно превращаться в «I have to Go».
//   Односложное английское слово почти всегда встретится в своём прямом
//   значении раньше, чем как название.
//
// Набор не хранится в настройках: он живёт в коде и не занимает место в
// пользовательском словаре, у которого свой предел в 512 записей.

enum BuiltInSpellings {
    /// Пары «как пишет модель» → «как это пишется». Сопоставление
    /// регистронезависимое и по границам слова, поэтому строчная запись
    /// слева ловит и «Postgres», и «POSTGRES».
    static let all: [TranscriptCorrection] = pairs.map {
        TranscriptCorrection(source: $0.0, replacement: $0.1)
    }

    static var count: Int { pairs.count }

    private static let pairs: [(String, String)] = [
        // Языки и платформы
        ("javascript", "JavaScript"), ("typescript", "TypeScript"),
        ("nodejs", "Node.js"), ("node js", "Node.js"),
        ("python", "Python"), ("java", "Java"), ("kotlin", "Kotlin"),
        ("objective c", "Objective-C"), ("c sharp", "C#"), ("c plus plus", "C++"),
        ("dotnet", ".NET"), ("dot net", ".NET"), ("php", "PHP"), ("perl", "Perl"),
        ("scala", "Scala"), ("haskell", "Haskell"), ("elixir", "Elixir"),
        ("webassembly", "WebAssembly"), ("wasm", "WebAssembly"),

        // Веб-фреймворки и сборка
        ("reactjs", "React"), ("react js", "React"), ("vuejs", "Vue"),
        ("angular", "Angular"), ("svelte", "Svelte"),
        ("nextjs", "Next.js"), ("next js", "Next.js"), ("nuxt", "Nuxt"),
        ("django", "Django"), ("flask", "Flask"), ("fastapi", "FastAPI"),
        ("laravel", "Laravel"), ("symfony", "Symfony"), ("rails", "Rails"),
        ("webpack", "Webpack"), ("vite", "Vite"), ("babel", "Babel"),
        ("eslint", "ESLint"), ("prettier", "Prettier"),
        ("npm", "npm"), ("pnpm", "pnpm"), ("yarn", "Yarn"),
        ("tailwind", "Tailwind"), ("bootstrap", "Bootstrap"),

        // Базы данных и очереди
        ("postgres", "PostgreSQL"), ("postgresql", "PostgreSQL"),
        ("postgres sql", "PostgreSQL"), ("msql", "MySQL"), ("mysql", "MySQL"),
        ("sqlite", "SQLite"), ("mongodb", "MongoDB"), ("mongo db", "MongoDB"),
        ("redis", "Redis"), ("clickhouse", "ClickHouse"),
        ("elasticsearch", "Elasticsearch"), ("opensearch", "OpenSearch"),
        ("kafka", "Kafka"), ("rabbitmq", "RabbitMQ"), ("rabbit mq", "RabbitMQ"),
        ("dynamodb", "DynamoDB"), ("supabase", "Supabase"), ("firebase", "Firebase"),

        // Инфраструктура
        ("kubernetes", "Kubernetes"), ("kubectl", "kubectl"),
        ("docker", "Docker"), ("dockerfile", "Dockerfile"),
        ("nginx", "nginx"), ("apache", "Apache"), ("traefik", "Traefik"),
        ("terraform", "Terraform"), ("ansible", "Ansible"),
        ("jenkins", "Jenkins"), ("gitlab", "GitLab"), ("github", "GitHub"),
        ("bitbucket", "Bitbucket"), ("grafana", "Grafana"),
        ("prometheus", "Prometheus"), ("kibana", "Kibana"),
        ("cloudflare", "Cloudflare"), ("vercel", "Vercel"), ("netlify", "Netlify"),
        ("heroku", "Heroku"), ("digitalocean", "DigitalOcean"),
        ("digital ocean", "DigitalOcean"), ("hetzner", "Hetzner"),
        ("linux", "Linux"), ("ubuntu", "Ubuntu"), ("debian", "Debian"),
        ("fedora", "Fedora"), ("centos", "CentOS"), ("windows", "Windows"),
        ("powershell", "PowerShell"), ("bash", "bash"), ("zsh", "zsh"),
        ("systemd", "systemd"), ("launchd", "launchd"),

        // Apple
        ("macos", "macOS"), ("mac os", "macOS"), ("ios", "iOS"),
        ("ipados", "iPadOS"), ("watchos", "watchOS"), ("tvos", "tvOS"),
        ("visionos", "visionOS"), ("xcode", "Xcode"),
        ("swiftui", "SwiftUI"), ("uikit", "UIKit"), ("appkit", "AppKit"),
        ("coredata", "Core Data"), ("core data", "Core Data"),
        ("testflight", "TestFlight"), ("iphone", "iPhone"), ("ipad", "iPad"),
        ("macbook", "MacBook"), ("imac", "iMac"), ("airpods", "AirPods"),
        ("icloud", "iCloud"), ("siri", "Siri"), ("finder", "Finder"),
        ("homebrew", "Homebrew"), ("appstore", "App Store"),
        ("app store", "App Store"),

        // Облака и сервисы
        ("aws", "AWS"), ("azure", "Azure"), ("gcp", "GCP"),
        ("bigquery", "BigQuery"), ("cloudfront", "CloudFront"),
        ("lambda", "Lambda"), ("s3", "S3"),

        // Инструменты и рабочие приложения
        ("vs code", "VS Code"), ("vscode", "VS Code"),
        ("intellij", "IntelliJ"), ("pycharm", "PyCharm"), ("webstorm", "WebStorm"),
        ("jira", "Jira"), ("confluence", "Confluence"), ("figma", "Figma"),
        ("notion", "Notion"), ("trello", "Trello"), ("asana", "Asana"),
        ("slack", "Slack"), ("telegram", "Telegram"), ("whatsapp", "WhatsApp"),
        ("zoom", "Zoom"), ("miro", "Miro"), ("photoshop", "Photoshop"),
        ("illustrator", "Illustrator"), ("excel", "Excel"),
        ("powerpoint", "PowerPoint"), ("onedrive", "OneDrive"),
        ("sharepoint", "SharePoint"), ("outlook", "Outlook"), ("gmail", "Gmail"),
        ("youtube", "YouTube"), ("linkedin", "LinkedIn"),
        ("chatgpt", "ChatGPT"), ("openai", "OpenAI"), ("anthropic", "Anthropic"),
        ("midjourney", "Midjourney"), ("copilot", "Copilot"),

        // Машинное обучение
        ("pytorch", "PyTorch"), ("tensorflow", "TensorFlow"),
        ("numpy", "NumPy"), ("scikit learn", "scikit-learn"),
        ("jupyter", "Jupyter"), ("huggingface", "Hugging Face"),
        ("hugging face", "Hugging Face"), ("cuda", "CUDA"),
        ("nvidia", "NVIDIA"), ("coreml", "Core ML"), ("core ml", "Core ML"),

        // Аббревиатуры: их модель почти всегда пишет строчными
        ("sql", "SQL"), ("api", "API"), ("rest", "REST"), ("graphql", "GraphQL"),
        ("json", "JSON"), ("yaml", "YAML"), ("xml", "XML"), ("csv", "CSV"),
        ("html", "HTML"), ("css", "CSS"), ("scss", "SCSS"),
        ("http", "HTTP"), ("https", "HTTPS"), ("url", "URL"), ("uri", "URI"),
        ("dns", "DNS"), ("vpn", "VPN"), ("ssh", "SSH"), ("ssl", "SSL"),
        ("tls", "TLS"), ("cdn", "CDN"), ("tcp", "TCP"), ("udp", "UDP"),
        ("ip", "IP"), ("uuid", "UUID"), ("jwt", "JWT"), ("oauth", "OAuth"),
        ("sdk", "SDK"), ("ide", "IDE"), ("cli", "CLI"), ("gui", "GUI"),
        ("orm", "ORM"), ("crud", "CRUD"), ("mvp", "MVP"), ("kpi", "KPI"),
        ("roi", "ROI"), ("crm", "CRM"), ("erp", "ERP"), ("saas", "SaaS"),
        ("paas", "PaaS"), ("iaas", "IaaS"), ("qa", "QA"), ("ui", "UI"),
        ("ux", "UX"), ("llm", "LLM"), ("rag", "RAG"), ("gpt", "GPT"),
        ("asr", "ASR"), ("tts", "TTS"), ("ocr", "OCR"), ("cpu", "CPU"),
        ("gpu", "GPU"), ("ram", "RAM"), ("ssd", "SSD"), ("hdd", "HDD"),
        ("usb", "USB"), ("pdf", "PDF"), ("png", "PNG"), ("jpeg", "JPEG"),
        ("svg", "SVG"), ("gif", "GIF"), ("mp3", "MP3"), ("mp4", "MP4"),
        ("wifi", "Wi-Fi"), ("wi fi", "Wi-Fi"), ("bluetooth", "Bluetooth"),
        ("ci cd", "CI/CD"), ("devops", "DevOps"), ("b2b", "B2B"), ("b2c", "B2C"),
    ]
}
