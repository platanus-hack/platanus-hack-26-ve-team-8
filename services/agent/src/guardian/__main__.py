import argparse
import json
import signal
from pathlib import Path

from .service import GuardianService, default_socket, serve
from .store import Store


def main():
    parser = argparse.ArgumentParser(description="Guardian: investigador defensivo local")
    parser.add_argument("command", choices=["serve", "scan", "investigate", "status"])
    parser.add_argument("--data-dir", type=Path, default=Path.home() / "Library/Application Support/Guardian")
    parser.add_argument("--socket", type=Path, default=default_socket())
    parser.add_argument("--watch", action="store_true", help="Recolecta cada cinco segundos mientras el servicio en primer plano está activo")
    parser.add_argument("--auto-investigate", action="store_true", help="Investiga la evidencia modificada como máximo una vez por minuto con el modelo configurado")
    parser.add_argument("--question", default="", help="Pregunta opcional para la investigación")
    args = parser.parse_args()
    service = GuardianService(Store(args.data_dir / "guardian.sqlite3"))
    if args.command == "serve":
        service.monitoring = args.watch
        def terminate(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, terminate)
        try:
            serve(service, args.socket, args.auto_investigate)
        except KeyboardInterrupt:
            pass
    elif args.command == "scan":
        print(json.dumps(service.scan(), indent=2))
    elif args.command == "investigate":
        print(json.dumps(service.investigate(args.question), indent=2))
    else:
        print(json.dumps(service.status(), indent=2))


if __name__ == "__main__":
    main()
