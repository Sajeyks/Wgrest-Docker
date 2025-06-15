# IP-Tables check commands

Use this to check for Ip Tables rules:

```bash
echo "📊 Complete WireGuard Firewall Status:"
echo ""
echo "=== INPUT Rules (Port Access) ==="
sudo iptables -L INPUT -v -n --line-numbers | grep -E "(51820|51821|51800|8090)"
echo ""
echo "=== FORWARD Rules (Interface Routing) ==="
sudo iptables -L FORWARD -v -n --line-numbers | grep -E "(wg0|wg1)"
echo ""
echo "=== NAT Rules (IP Masquerading) ==="
sudo iptables -t nat -L POSTROUTING -v -n --line-numbers | grep -E "(10\.10\.|10\.11\.)"
echo ""
echo "=== Rule Counts (Should be 4, 3, 2) ==="
echo "INPUT: $(sudo iptables -L INPUT -n | grep -E '(51820|51821|51800|8090)' | wc -l) rules"
echo "FORWARD: $(sudo iptables -L FORWARD -n | grep -E '(wg0|wg1)' | wc -l) rules"
echo "NAT: $(sudo iptables -t nat -L POSTROUTING -n | grep -E '(10\.10\.|10\.11\.)' | wc -l) rules"
```
