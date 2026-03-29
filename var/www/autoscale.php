<?php
require(__DIR__ . '/common.php');
$db = get_db_instance();

$accounts_per_instance = 250;

function next_instance_id(array $existing): string {
	// a-z, then aa, ab, ... az, ba, ...
	if(empty($existing)){
		return 'a';
	}
	$last = end($existing);
	$len = strlen($last);
	for($i = $len - 1; $i >= 0; $i--){
		if($last[$i] !== 'z'){
			$last[$i] = chr(ord($last[$i]) + 1);
			return $last;
		}
		$last[$i] = 'a';
	}
	return str_repeat('a', $len + 1);
}

$stmt = $db->query('SELECT instance, COUNT(*) as cnt FROM onions WHERE enabled IN (1, -2) GROUP BY instance;');
$loads = [];
while($row = $stmt->fetch(PDO::FETCH_ASSOC)){
	$loads[$row['instance']] = (int)$row['cnt'];
}

$current = SERVICE_INSTANCES;
$total_accounts = array_sum($loads);
$needed = max(1, (int)ceil($total_accounts / $accounts_per_instance));

if($needed <= count($current)){
	echo "OK: $total_accounts accounts across " . count($current) . " instance(s)\n";
	exit(0);
}

$new_instances = $current;
while(count($new_instances) < $needed){
	$new_instances[] = next_instance_id($new_instances);
}

$old_str = "const SERVICE_INSTANCES=['" . implode("','", $current) . "']";
$new_str = "const SERVICE_INSTANCES=['" . implode("','", $new_instances) . "']";

$common = file_get_contents('/var/www/common.php');
if(strpos($common, $old_str) === false){
	echo "ERROR: could not find SERVICE_INSTANCES in common.php\n";
	exit(1);
}

file_put_contents('/var/www/common.php', str_replace($old_str, $new_str, $common));
echo "SCALED: $total_accounts accounts, " . count($current) . " -> " . count($new_instances) . " instances\n";

require(__DIR__ . '/setup.php');
