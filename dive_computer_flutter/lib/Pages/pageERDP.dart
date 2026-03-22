import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/erdp.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';

enum ErdpNodeType { dive, surface }

// 각 다이빙/휴식 단계를 관리할 상태 모델
class ErdpNode {
  final ErdpNodeType type;
  final TextEditingController depthCtrl = TextEditingController();
  final TextEditingController timeCtrl = TextEditingController();

  String pgIn = '-';
  String pgOut = '-';
  int rnt = 0; // 잔류 질소 시간
  int andl = 0; // 조정된 무감압 한계 시간

  ErdpNode({required this.type, required VoidCallback onChanged}) {
    depthCtrl.addListener(onChanged);
    timeCtrl.addListener(onChanged);
  }

  void dispose() {
    depthCtrl.dispose();
    timeCtrl.dispose();
  }
}

class PageErdp extends StatefulWidget {
  const PageErdp({super.key});

  @override
  State<PageErdp> createState() => _PageErdpState();
}

class _PageErdpState extends State<PageErdp> {
  final List<ErdpNode> _nodes = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 처음 시작 시 '다이빙 1' 노드를 기본 생성
    _addNode(ErdpNodeType.dive);
  }

  @override
  void dispose() {
    for (var node in _nodes) {
      node.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  // 노드 추가 (입력 변경 시 자동 계산되도록 리스너 연결)
  void _addNode(ErdpNodeType type) {
    setState(() {
      _nodes.add(ErdpNode(type: type, onChanged: _calculateAll));
    });
    _scrollToBottom();
  }

  void _removeLastNode() {
    if (_nodes.length > 1) {
      setState(() {
        var node = _nodes.removeLast();
        node.dispose();
        _calculateAll();
      });
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // 🌟 [핵심 로직] 위에서부터 아래로 순차적으로 eRDP 계산
  void _calculateAll() {
    String currentPG = '-';

    for (var node in _nodes) {
      node.pgIn = currentPG;

      if (node.type == ErdpNodeType.dive) {
        double depth = double.tryParse(node.depthCtrl.text) ?? 0.0;
        int time = int.tryParse(node.timeCtrl.text) ?? 0;

        if (depth > 0) {
          // ANDL 및 RNT 계산
          node.rnt = PadiERdp.getResidualNitrogenTime(currentPG, depth);
          node.andl = PadiERdp.getAdjustedNDL(currentPG, depth);

          if (time > 0) {
            int totalBottomTime = time + node.rnt;
            node.pgOut = PadiERdp.getPressureGroup(depth, totalBottomTime);
            currentPG = node.pgOut;
          } else {
            node.pgOut = '-';
            currentPG = '-';
          }
        } else {
          node.pgOut = '-';
          currentPG = '-';
          node.rnt = 0;
          node.andl = 0;
        }
      } else if (node.type == ErdpNodeType.surface) {
        int time = int.tryParse(node.timeCtrl.text) ?? 0;
        if (time > 0 && currentPG != '-' && currentPG != 'OOR') {
          node.pgOut = PadiERdp.getNewPressureGroupAfterSurfaceInterval(
            currentPG,
            time,
          );
          currentPG = node.pgOut;
        } else {
          node.pgOut = currentPG;
        }
      }
    }
    setState(() {}); // UI 업데이트
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('eRDPml Calculator').color(Colors.white),
        backgroundColor: colorMain,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Go to the diving simulator',
            onPressed: () {
              context.goNamed(RoutePage.home.name);
            },
            icon: const Icon(Icons.scuba_diving, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Go to the diving planner',
            onPressed: () {
              context.goNamed(RoutePage.planner.name);
            },
            icon: const Icon(Icons.assignment, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Clear All',
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              setState(() {
                for (var n in _nodes) {
                  n.dispose();
                }
                _nodes.clear();
                _addNode(ErdpNodeType.dive);
                _calculateAll();
              });
            },
          ),
          IconButton(
            tooltip: 'About eRDP',
            icon: const Icon(Icons.help_outline, color: Colors.white),
            onPressed: () {
              showGetDialog(
                'PADI eRDPml Mode',
                'This calculator uses the recreational dive planner (RDP) table algorithms.\n\n'
                    '1. Enter Depth & Bottom Time to get your Pressure Group (PG).\n'
                    '2. Add a Surface Interval to see your new PG.\n'
                    '3. Add Repetitive Dives to automatically calculate your Residual Nitrogen Time (RNT) and Adjusted NDL (ANDL).',
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 600,
          ), // 데스크탑에서도 모바일처럼 세로형 유지
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15),
          child: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _nodes.length,
                  itemBuilder: (context, index) {
                    var node = _nodes[index];
                    int diveNumber = _nodes
                        .sublist(0, index + 1)
                        .where((n) => n.type == ErdpNodeType.dive)
                        .length;

                    if (node.type == ErdpNodeType.dive) {
                      return _buildDiveCard(node, diveNumber);
                    } else {
                      return _buildSurfaceCard(node);
                    }
                  },
                ),
              ),
              const SizedBox(height: 10),
              _buildControlButtons(),
            ],
          ),
        ),
      ),
    );
  }

  // --- 다이빙 입력 카드 ---
  Widget _buildDiveCard(ErdpNode node, int diveNumber) {
    bool hasRnt = node.pgIn != '-' && node.pgIn != 'OOR';
    bool isOor = node.pgOut == 'OOR';

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 15),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorMain.withOpacity(0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.scuba_diving, color: colorMain, size: 24),
                const SizedBox(width: 8),
                Text(
                  'Dive #$diveNumber',
                ).weight(FontWeight.bold).size(18).color(colorMain),
                const Spacer(),
                if (hasRnt)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Starting PG: ${node.pgIn}',
                    ).weight(FontWeight.bold).color(Colors.orange[800]!),
                  ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Depth (m)').color(Colors.black54).size(12),
                      const SizedBox(height: 5),
                      InputText(
                        controller: node.depthCtrl,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d*$'),
                          ),
                        ],
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Bottom Time (min)',
                      ).color(Colors.black54).size(12),
                      const SizedBox(height: 5),
                      InputText(
                        controller: node.timeCtrl,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (node.depthCtrl.text.isNotEmpty) ...[
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    if (hasRnt) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Adjusted NDL (ANDL):',
                          ).color(Colors.black87),
                          Text('${node.andl} min')
                              .weight(FontWeight.bold)
                              .color(
                                node.andl > 0 ? Colors.green[700]! : Colors.red,
                              ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Residual Nitrogen Time (RNT):',
                          ).color(Colors.black87),
                          Text(
                            '+ ${node.rnt} min',
                          ).weight(FontWeight.bold).color(Colors.orange[800]!),
                        ],
                      ),
                      const Divider(height: 15),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Ending Pressure Group:',
                        ).size(16).weight(FontWeight.bold).color(colorMain),
                        Text(isOor ? 'DECO / OOR' : node.pgOut)
                            .size(20)
                            .weight(FontWeight.bold)
                            .color(isOor ? Colors.red : colorMain),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- 수면 휴식 입력 카드 ---
  Widget _buildSurfaceCard(ErdpNode node) {
    return Card(
      elevation: 0,
      color: Colors.teal.withOpacity(0.1),
      margin: const EdgeInsets.only(bottom: 15),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.teal.withOpacity(0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.waves, color: Colors.teal, size: 24),
                const SizedBox(width: 8),
                const Text(
                  'Surface Interval',
                ).weight(FontWeight.bold).size(16).color(Colors.teal),
                const Spacer(),
                Text(
                  'PG In: ${node.pgIn}',
                ).weight(FontWeight.bold).color(Colors.teal[800]!),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Time Spent (min):',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: InputText(
                    controller: node.timeCtrl,
                    textAlign: TextAlign.center,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            if (node.timeCtrl.text.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Text('New PG: ').size(15).color(Colors.teal[800]!),
                  Text(
                    node.pgOut,
                  ).size(18).weight(FontWeight.bold).color(Colors.teal[900]!),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- 하단 추가/삭제 컨트롤 버튼 ---
  Widget _buildControlButtons() {
    bool isLastDive = _nodes.last.type == ErdpNodeType.dive;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_nodes.length > 1)
          IconButton(
            icon: const Icon(Icons.undo, color: Colors.redAccent),
            tooltip: 'Remove Last Step',
            onPressed: _removeLastNode,
          ).marginOnly(right: 10),
        Expanded(
          child: Button(
            height: 50,
            color: isLastDive ? Colors.teal : colorMain,
            onPressed: () {
              _addNode(isLastDive ? ErdpNodeType.surface : ErdpNodeType.dive);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isLastDive ? Icons.waves : Icons.scuba_diving,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  isLastDive ? 'Add Surface Interval' : 'Add Repetitive Dive',
                ).color(Colors.white).weight(FontWeight.bold),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
